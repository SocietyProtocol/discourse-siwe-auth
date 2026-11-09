#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit tests for the badge -> group sync: ABI helpers, on-chain balance
# reads, address derivation, mapping parser, planner and the orchestrator's
# safety rules. No Discourse or network needed.
#
# Run: ruby -r./test/support/pure_keccak -rtime test/group_sync_unit_test.rb

require 'json'
require 'set'
require 'tempfile'
require 'tmpdir'
require 'minitest/autorun'
require_relative '../lib/discourse_siwe/eth_rpc'
require_relative '../lib/discourse_siwe/member_addresses'
require_relative '../lib/discourse_siwe/badge_group_mapping'
require_relative '../lib/discourse_siwe/badge_ownership'
require_relative '../lib/discourse_siwe/group_sync_planner'
require_relative '../lib/discourse_siwe/badge_group_sync'

Rpc = DiscourseSiwe::EthRpc
Own = DiscourseSiwe::BadgeOwnership

class AbiHelpersTest < Minitest::Test
  def test_selectors_match_the_erc1155_standard
    assert_equal '4e1273f4', Own.selector(Own::BATCH_SIGNATURE)
    assert_equal '00fdd58e', Own.selector(Own::BALANCE_OF_SIGNATURE)
  end

  def test_uint256_list_roundtrip_through_a_return_payload
    payload = Rpc.encode_uint256(32) + Rpc.encode_uint256_list([0, 1, 15])
    assert_equal [0, 1, 15], Rpc.decode_uint256_list(payload)
  end

  def test_decoding_rejects_a_truncated_or_empty_array
    assert_raises(Rpc::Error) { Rpc.decode_uint256_list('') }
    truncated = Rpc.encode_uint256(32) + Rpc.encode_uint256(3) + Rpc.encode_uint256(1)
    assert_raises(Rpc::Error) { Rpc.decode_uint256_list(truncated) }
  end

  def test_batch_calldata_layout_is_pairwise_with_correct_offsets
    a = '0x' + 'aa' * 20
    b = '0x' + 'bb' * 20
    data = Own.batch_calldata([a, b], [13, 14])
    body = data.sub(/\A0x4e1273f4/, '')
    words = body.scan(/.{64}/)
    assert_equal 64, words[0].to_i(16)                       # offset of accounts
    assert_equal 64 + 32 + 2 * 32, words[1].to_i(16)         # offset of ids
    assert_equal 2, words[2].to_i(16)                        # accounts length
    assert_equal ('aa' * 20).rjust(64, '0'), words[3]
    assert_equal ('bb' * 20).rjust(64, '0'), words[4]
    assert_equal 2, words[5].to_i(16)                        # ids length
    assert_equal [13, 14], [words[6].to_i(16), words[7].to_i(16)]
  end

  def test_batch_calldata_requires_equal_lengths
    assert_raises(ArgumentError) { Own.batch_calldata(['0x' + 'aa' * 20], [1, 2]) }
  end
end

# Scripted RPC: delegates the pure helpers to the real module and answers
# the network calls from a table.
class FakeRpc
  attr_reader :calls

  def initialize(chain_id: 1, code: '6080', balances: {}, batch_fails: false, down: false)
    @chain_id = chain_id
    @code = code
    @balances = balances # { [address, id] => Integer }
    @batch_fails = batch_fails
    @down = down
    @calls = []
  end

  def method_missing(name, *args, &block)
    Rpc.public_send(name, *args, &block)
  end

  def respond_to_missing?(name, include_private = false)
    Rpc.respond_to?(name, include_private) || super
  end

  def chain_id(url:)
    raise Rpc::Error, 'down' if @down

    @chain_id
  end

  def get_code_strict(_address, url:)
    raise Rpc::Error, 'down' if @down

    @code
  end

  def eth_call_strict(_to, data, url:, block: 'latest')
    raise Rpc::Error, 'down' if @down

    @calls << data[0, 10]
    if data.start_with?('0x4e1273f4')
      raise Rpc::Error, 'execution reverted' if @batch_fails

      words = data.sub('0x4e1273f4', '').scan(/.{64}/)
      count = words[2].to_i(16)
      accounts = (0...count).map { |i| '0x' + words[3 + i][-40, 40] }
      ids = (0...count).map { |i| words[4 + count + i].to_i(16) }
      values = accounts.zip(ids).map { |pair| @balances.fetch(pair, 0) }
      Rpc.encode_uint256(32) + Rpc.encode_uint256_list(values)
    else
      words = data.sub('0x00fdd58e', '').scan(/.{64}/)
      address = '0x' + words[0][-40, 40]
      id = words[1].to_i(16)
      raise Rpc::Error, 'hook reverted' if @balances[[address, id]] == :revert

      Rpc.encode_uint256(@balances.fetch([address, id], 0))
    end
  end
end

class BadgeOwnershipTest < Minitest::Test
  A = '0x' + 'aa' * 20
  B = '0x' + 'bb' * 20
  CONTRACT = '0x' + 'cc' * 20

  def read(rpc, addresses: [A, B], ids: [13, 14], **opts)
    Own.balances(addresses, ids, contract: CONTRACT, url: 'http://rpc', rpc: rpc, **opts)
  end

  def test_reads_pairwise_balances_in_one_batch
    rpc = FakeRpc.new(balances: { [A, 13] => 2, [B, 14] => 1 })
    result = read(rpc)
    assert_equal({ 13 => 2, 14 => 0 }, result[A])
    assert_equal({ 13 => 0, 14 => 1 }, result[B])
    assert_equal ['0x4e1273f4'], rpc.calls
  end

  def test_zero_is_not_unknown
    result = read(FakeRpc.new)
    assert_equal 0, result[A][13]
  end

  def test_chunks_large_requests
    rpc = FakeRpc.new
    read(rpc, chunk: 2)
    assert_equal 2, rpc.calls.size # 4 pairs in chunks of 2
  end

  def test_a_reverting_batch_falls_back_to_single_reads_and_marks_only_the_bad_pair_unknown
    rpc = FakeRpc.new(batch_fails: true, balances: { [A, 13] => 1, [B, 14] => :revert })
    result = read(rpc)
    assert_equal 1, result[A][13]
    assert_equal 0, result[A][14]
    assert_nil result[B][14], 'a reverting hook is unknown, never zero'
  end

  def test_a_dead_rpc_fails_fast_instead_of_timing_out_per_pair
    rpc = FakeRpc.new(batch_fails: true, balances: Hash.new(:revert))
    many = (1..10).map { |i| '0x' + i.to_s(16).rjust(40, '0') }
    assert_raises(Own::SourceError) { read(rpc, addresses: many, ids: [13, 14, 15]) }
  end

  def test_wrong_chain_is_refused
    err = assert_raises(Own::SourceError) { read(FakeRpc.new(chain_id: 1), expected_chain_id: 11_155_111) }
    assert_match(/wrong chain/, err.message)
  end

  def test_contract_without_code_is_refused
    assert_raises(Own::SourceError) { read(FakeRpc.new(code: '')) }
  end

  def test_unreachable_rpc_is_a_source_error
    assert_raises(Own::SourceError) { read(FakeRpc.new(down: true)) }
  end

  def test_nothing_to_read
    assert_empty read(FakeRpc.new, addresses: [])
  end
end

class MemberAddressesTest < Minitest::Test
  EOA = '0x' + '11' * 20
  SMART = '0x' + '22' * 20 # second address of the same person
  MAP = { EOA => SMART }.freeze

  def addresses(fields, map = {})
    DiscourseSiwe::MemberAddresses.addresses_for(fields, address_map: map)
  end

  def test_plain_eoa
    assert_equal [EOA], addresses('wallet_address' => EOA.upcase.sub('0X', '0x'))
  end

  def test_second_address_with_stored_owner
    assert_equal [EOA, SMART], addresses('wallet_address' => SMART, 'siwe_owner_address' => EOA)
  end

  def test_wallet_also_covers_its_paired_address_from_the_map
    assert_equal [EOA, SMART], addresses({ 'wallet_address' => EOA }, MAP)
  end

  def test_second_address_without_a_stored_owner_finds_its_pair_in_the_map
    assert_equal [EOA, SMART], addresses({ 'wallet_address' => SMART }, MAP)
  end

  def test_invalid_and_missing_values_are_dropped
    assert_equal [], addresses('wallet_address' => 'nope', 'siwe_owner_address' => '')
    assert_equal [], addresses({})
  end

  def test_a_plain_wallet_with_no_owner_and_no_map_is_just_itself
    assert_equal [EOA], addresses({ 'wallet_address' => EOA })
    assert_equal [EOA], addresses({ 'wallet_address' => EOA }, nil)
  end

  def test_an_owner_without_a_wallet_is_still_covered
    assert_equal [EOA], addresses('siwe_owner_address' => EOA)
  end

  def test_load_address_map_flat_and_chain_keyed
    flat = Tempfile.new('map')
    flat.write({ EOA => SMART }.to_json)
    flat.flush
    assert_equal MAP, DiscourseSiwe::MemberAddresses.load_address_map(flat.path)

    keyed = Tempfile.new('map')
    other = { '0x' + '33' * 20 => '0x' + '44' * 20 }
    keyed.write({ '1' => { EOA => SMART }, '11155111' => other }.to_json)
    keyed.flush
    assert_equal MAP, DiscourseSiwe::MemberAddresses.load_address_map(keyed.path, chain_id: 1)
    assert_equal other, DiscourseSiwe::MemberAddresses.load_address_map(keyed.path, chain_id: 11_155_111)
    assert_equal MAP.merge(other), DiscourseSiwe::MemberAddresses.load_address_map(keyed.path)
  end

  # script/forum-address-map.json does not exist in this plugin version; the
  # group sync must work with no map at all.
  def test_nil_blank_missing_or_broken_map_gives_an_empty_map
    assert_equal({}, DiscourseSiwe::MemberAddresses.load_address_map(nil))
    assert_equal({}, DiscourseSiwe::MemberAddresses.load_address_map(''))
    assert_equal({}, DiscourseSiwe::MemberAddresses.load_address_map(Dir.tmpdir))
    shipped = File.expand_path('../script/forum-address-map.json', __dir__)
    assert_equal({}, DiscourseSiwe::MemberAddresses.load_address_map(shipped))
    assert_equal({}, DiscourseSiwe::MemberAddresses.load_address_map('/no/such/file.json'))
    array = Tempfile.new('map')
    array.write('["0x1"]')
    array.flush
    assert_equal({}, DiscourseSiwe::MemberAddresses.load_address_map(array.path))
    bad = Tempfile.new('map')
    bad.write('{not json')
    bad.flush
    assert_equal({}, DiscourseSiwe::MemberAddresses.load_address_map(bad.path))
  end
end

class BadgeGroupMappingTest < Minitest::Test
  def parse(text, **opts)
    DiscourseSiwe::BadgeGroupMapping.parse(text, **opts)
  end

  def test_many_to_one_and_one_to_many
    r = parse('14:vip|15:vip|16:vip|13:governors|13:voters')
    assert_equal({ 'vip' => [14, 15, 16], 'governors' => [13], 'voters' => [13] }, r.groups)
    assert_empty r.errors
  end

  def test_junk_entries_are_reported_and_ignored
    r = parse('13:governors|junk|:x|14:|abc:g|13:bad name!')
    assert_equal({ 'governors' => [13] }, r.groups)
    assert_equal 5, r.errors.size
  end

  def test_automatic_groups_are_refused_case_insensitively
    r = parse('28:Moderators|1:admins|2:trust_level_3|3:staff|4:everyone|13:governors')
    assert_equal({ 'governors' => [13] }, r.groups)
    assert_equal 5, r.errors.size
  end

  def test_caller_can_forbid_more_names
    assert_empty parse('13:custom_auto', reserved: ['custom_auto']).groups
  end

  def test_blank_and_whitespace
    assert_empty parse('').groups
    assert_empty parse(nil).groups
    assert_equal({ 'g' => [1] }, parse(' 1 : g | ').groups)
  end

  def test_badge_ids_are_unique_and_sorted
    assert_equal [13, 14, 15], DiscourseSiwe::BadgeGroupMapping.badge_ids('a' => [15, 13], 'b' => [14, 13])
  end
end

class GroupSyncPlannerTest < Minitest::Test
  def plan(desired: [], current: [], protected: [], unknown: [], pending: {}, **opts)
    DiscourseSiwe::GroupSyncPlanner.plan(
      desired: Set.new(desired), current: Set.new(current), protected: Set.new(protected),
      unknown: Set.new(unknown), pending: pending, **opts
    )
  end

  def test_adds_holders_not_yet_members
    assert_equal [3, 4], plan(desired: [1, 3, 4], current: [1]).add
  end

  def test_removal_waits_for_confirmation
    first = plan(desired: [], current: [5], confirmations: 2)
    assert_empty first.remove
    assert_equal [5], first.deferred
    assert_equal({ 5 => 1 }, first.next_pending)

    second = plan(desired: [], current: [5], pending: { 5 => 1 }, confirmations: 2)
    assert_equal [5], second.remove
  end

  def test_one_confirmation_removes_immediately
    assert_equal [5], plan(current: [5], confirmations: 1).remove
  end

  def test_a_member_who_holds_again_drops_out_of_pending
    assert_empty plan(desired: [5], current: [5], pending: { 5 => 1 }).next_pending
  end

  def test_protected_members_are_never_removed
    p = plan(current: [1, 2], protected: [1], pending: { 1 => 9, 2 => 9 })
    assert_equal [2], p.remove
    assert_equal [1], p.kept
  end

  def test_unknown_holdings_are_never_removed_even_when_confirmed
    p = plan(current: [1], unknown: [1], pending: { 1 => 9 })
    assert_empty p.remove
    assert_empty p.deferred
    assert_empty p.next_pending
  end

  def test_brake_blocks_all_removals_when_too_many_at_once
    members = (1..10).to_a
    pending = members.to_h { |id| [id, 1] }
    p = plan(current: members, pending: pending, floor: 3, percent: 20)
    assert p.braked
    assert_empty p.remove
    assert_equal 10, p.next_pending.size, 'counters survive a braked run'
  end

  def test_brake_allows_up_to_the_floor_on_a_tiny_group
    # Governor-sized group: 2 members, floor 3, so losing both is allowed.
    p = plan(current: [1, 2], pending: { 1 => 1, 2 => 1 }, floor: 3, percent: 20)
    refute p.braked
    assert_equal [1, 2], p.remove
  end

  def test_brake_percent_scales_with_large_groups
    members = (1..100).to_a
    pending = members.first(20).to_h { |id| [id, 1] }
    allowed = plan(current: members, desired: members.last(80), pending: pending, floor: 3, percent: 20)
    refute allowed.braked
    assert_equal 20, allowed.remove.size

    blocked = plan(current: members, desired: members.last(79), pending: members.first(21).to_h { |id| [id, 1] },
                   floor: 3, percent: 20)
    assert blocked.braked
  end

  def test_idempotent_when_already_in_sync
    p = plan(desired: [1, 2], current: [1, 2])
    assert_empty p.add
    assert_empty p.remove
    assert_empty p.deferred
  end
end

class FakeGroups
  attr_reader :added, :removed

  def initialize(groups, owners: {})
    @groups = groups.transform_values { |ids| Set.new(ids) }
    @owners = owners
    @added = []
    @removed = []
  end

  def members(name)
    @groups[name]
  end

  def protected_members(name)
    Set.new(@owners.fetch(name, []))
  end

  def add(name, user_id)
    @added << [name, user_id]
    @groups[name] << user_id
  end

  def remove(name, user_id)
    @removed << [name, user_id]
    @groups[name].delete(user_id)
  end
end

class FakeState
  attr_reader :saved

  def initialize(pending = {})
    @pending = pending
  end

  def pending
    @pending
  end

  def save_pending(value)
    @saved = value
  end
end

class BadgeGroupSyncTest < Minitest::Test
  E1 = '0x' + '01' * 20
  E2 = '0x' + '02' * 20
  E3 = '0x' + '03' * 20

  USERS = [
    { id: 1, username: 'alice', addresses: [E1], protected: false },
    { id: 2, username: 'bob', addresses: [E2], protected: false },
    { id: 3, username: 'carol', addresses: [E3], protected: false },
    { id: 4, username: 'nowallet', addresses: [], protected: false },
  ].freeze

  def sync(balances:, groups:, mapping: { 'governors' => [13] }, users: USERS, state: FakeState.new, owners: {},
           ownership: nil, **opts)
    fake_groups = FakeGroups.new(groups, owners: owners)
    ownership ||= ->(_addresses, _ids) { balances }
    runner = DiscourseSiwe::BadgeGroupSync.new(
      mapping: mapping, users: users, ownership: ownership, groups: fake_groups, state: state,
      confirmations: 1, **opts
    )
    [runner, fake_groups, state]
  end

  def test_log_mode_reports_but_changes_nothing
    runner, groups, state = sync(balances: { E1 => { 13 => 1 }, E2 => { 13 => 0 } }, groups: { 'governors' => [2] })
    result = runner.run(mode: 'log')
    assert_equal :ok, result[:status]
    assert_equal %w[alice], result[:groups]['governors'][:add]
    assert_equal %w[bob], result[:groups]['governors'][:remove]
    assert_empty groups.added
    assert_empty groups.removed
    assert_nil state.saved
  end

  def test_enforce_adds_and_removes
    runner, groups, = sync(balances: { E1 => { 13 => 1 }, E2 => { 13 => 0 } }, groups: { 'governors' => [2] })
    runner.run(mode: 'enforce')
    assert_equal [['governors', 1]], groups.added
    assert_equal [['governors', 2]], groups.removed
  end

  def test_second_run_is_a_no_op
    balances = { E1 => { 13 => 1 }, E2 => { 13 => 0 } }
    runner, groups, = sync(balances: balances, groups: { 'governors' => [2] })
    runner.run(mode: 'enforce')
    runner.run(mode: 'enforce')
    assert_equal [['governors', 1]], groups.added
    assert_equal [['governors', 2]], groups.removed
  end

  def test_a_source_error_changes_nothing_and_is_reported
    failing = ->(_a, _i) { raise DiscourseSiwe::BadgeOwnership::SourceError, 'wrong chain' }
    runner, groups, = sync(balances: {}, groups: { 'governors' => [1, 2] }, ownership: failing)
    result = runner.run(mode: 'enforce')
    assert_equal :source_error, result[:status]
    assert_equal 'wrong chain', result[:error]
    assert_empty groups.added
    assert_empty groups.removed
  end

  def test_nothing_readable_is_treated_as_a_source_error_not_as_zero_holdings
    all_nil = { E1 => { 13 => nil }, E2 => { 13 => nil }, E3 => { 13 => nil } }
    runner, groups, = sync(balances: all_nil, groups: { 'governors' => [1, 2, 3] })
    result = runner.run(mode: 'enforce')
    assert_equal :source_error, result[:status]
    assert_empty groups.removed
  end

  def test_an_unknown_balance_protects_that_member_from_removal
    runner, groups, = sync(balances: { E1 => { 13 => 1 }, E2 => { 13 => nil }, E3 => { 13 => 0 } },
                           groups: { 'governors' => [1, 2, 3] })
    runner.run(mode: 'enforce')
    assert_equal [['governors', 3]], groups.removed
  end

  def test_holding_on_either_address_counts
    both = [{ id: 1, username: 'alice', addresses: [E1, E2], protected: false }]
    runner, groups, = sync(balances: { E1 => { 13 => 0 }, E2 => { 13 => 3 } }, groups: { 'governors' => [] }, users: both)
    runner.run(mode: 'enforce')
    assert_equal [['governors', 1]], groups.added
  end

  def test_an_unknown_second_address_does_not_cancel_a_known_holding
    both = [{ id: 1, username: 'alice', addresses: [E1, E2], protected: false }]
    runner, groups, = sync(balances: { E1 => { 13 => 1 }, E2 => { 13 => nil } }, groups: { 'governors' => [] }, users: both)
    runner.run(mode: 'enforce')
    assert_equal [['governors', 1]], groups.added
  end

  def test_many_to_one_membership_is_per_group_not_per_entry
    mapping = { 'vip' => [14, 15, 16] }
    runner, groups, = sync(
      balances: { E1 => { 14 => 0, 15 => 1, 16 => 0 }, E2 => { 14 => 0, 15 => 0, 16 => 0 }, E3 => { 14 => 1, 15 => 0, 16 => 0 } },
      groups: { 'vip' => [1, 2] }, mapping: mapping
    )
    runner.run(mode: 'enforce')
    assert_equal [['vip', 3]], groups.added
    assert_equal [['vip', 2]], groups.removed, 'alice holds 15 and stays although 14 and 16 are zero'
  end

  def test_members_without_a_wallet_are_left_alone
    runner, groups, = sync(balances: { E1 => { 13 => 1 }, E2 => { 13 => 1 }, E3 => { 13 => 1 } },
                           groups: { 'governors' => [4] })
    runner.run(mode: 'enforce')
    assert_empty groups.removed
  end

  def test_staff_and_group_owners_are_never_removed
    users = USERS.map { |u| u[:id] == 2 ? u.merge(protected: true) : u }
    runner, groups, = sync(balances: { E1 => { 13 => 0 }, E2 => { 13 => 0 }, E3 => { 13 => 1 } },
                           groups: { 'governors' => [1, 2, 3] }, users: users, owners: { 'governors' => [3] })
    runner.run(mode: 'enforce')
    assert_equal [['governors', 1]], groups.removed
  end

  def test_add_only_never_removes_and_does_not_touch_the_counters
    runner, groups, state = sync(balances: { E1 => { 13 => 1 }, E2 => { 13 => 0 } }, groups: { 'governors' => [2] })
    runner.run(mode: 'enforce', add_only: true)
    assert_equal [['governors', 1]], groups.added
    assert_empty groups.removed
    assert_nil state.saved
  end

  def test_confirmations_persist_between_runs
    state = FakeState.new
    runner = lambda do
      sync(balances: { E1 => { 13 => 0 } }, groups: { 'governors' => [1] }, state: state,
           users: [USERS[0]], confirmations: 2).first
    end
    first = runner.call
    first.run(mode: 'enforce')
    assert_equal({ 'governors' => { 1 => 1 } }, state.saved)

    state = FakeState.new(state.saved)
    second, groups, = sync(balances: { E1 => { 13 => 0 } }, groups: { 'governors' => [1] }, state: state,
                           users: [USERS[0]], confirmations: 2)
    second.run(mode: 'enforce')
    assert_equal [['governors', 1]], groups.removed
  end

  def test_missing_group_is_reported_not_created
    runner, groups, = sync(balances: { E1 => { 13 => 1 } }, groups: {})
    result = runner.run(mode: 'enforce')
    assert result[:groups]['governors'][:missing]
    assert_empty groups.added
  end

  def test_empty_mapping_and_no_members
    runner, = sync(balances: {}, groups: {}, mapping: {})
    assert_equal :no_mapping, runner.run(mode: 'log')[:status]
    runner, = sync(balances: {}, groups: {}, users: [USERS[3]])
    assert_equal :no_members, runner.run(mode: 'log')[:status]
  end

  def test_rejects_an_unknown_mode
    runner, = sync(balances: {}, groups: {})
    assert_raises(ArgumentError) { runner.run(mode: 'delete-everything') }
  end

  def test_the_brake_blocks_a_mass_removal_but_still_adds
    ids = (10..29).to_a
    users = ids.map { |i| { id: i, username: "u#{i}", addresses: ['0x' + i.to_s(16).rjust(40, '0')], protected: false } }
    balances = users.to_h { |u| [u[:addresses].first, { 13 => 0 }] }
    runner, groups, = sync(balances: balances, groups: { 'governors' => ids.first(19) }, users: users,
                           floor: 3, percent: 20)
    result = runner.run(mode: 'enforce')
    assert result[:groups]['governors'][:braked]
    assert_empty groups.removed
  end
end
