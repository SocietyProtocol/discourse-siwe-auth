#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit tests for the Light Account derivation and the forum rewrite planner.
# No network or Discourse needed; uses a pure-Ruby Keccak when the keccak gem
# is missing.
#
# Run: ruby test/light_account_unit_test.rb

require_relative 'support/pure_keccak'
require 'json'
require 'time'
require 'minitest/autorun'
require_relative '../lib/discourse_siwe/eth_rpc'
require_relative '../lib/discourse_siwe/light_account'
require_relative '../lib/discourse_siwe/smart_account_rewrite'
require_relative '../lib/discourse_siwe/identity_resolver'

LA = DiscourseSiwe::LightAccount
REWRITE = DiscourseSiwe::SmartAccountRewrite
MAP_PATH = File.join(__dir__, '..', 'script', 'forum-address-map.json')

EOA = '0x9ba704115f0ed3a431a025ffa0525fdd1d507c3c'
SMART = '0xA47f4D7D2FAbDbfDCe865501ADc55a2b370c88cb'

# wrapLightAccountSignature(EOA, 0x11 * 65) from ui/src/lightAccount.ts (viem).
WRAPPED_SIGNATURE = '0x0000000000000000000000000000000000400cdfef5e2714e63d8040b700bc24000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000000445fbfb9cf0000000000000000000000009ba704115f0ed3a431a025ffa0525fdd1d507c3c00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000420011111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111110000000000000000000000000000000000000000000000000000000000006492649264926492649264926492649264926492649264926492649264926492'

class LightAccountTest < Minitest::Test
  def test_init_code_layout
    code = LA.init_code
    assert_equal 0x5f * 2, code.length
    assert_includes code, LA::IMPLEMENTATION[2..-1].downcase
    assert_equal code[68..-1], LA.proxy_runtime_code
  end

  def test_derives_every_pair_in_the_address_map
    pairs = REWRITE.address_pairs(JSON.parse(File.read(MAP_PATH)))
    refute_empty pairs
    pairs.each { |eoa, smart| assert_equal smart, LA.address(eoa), eoa }
  end

  def test_derivation_ignores_owner_case
    assert_equal SMART, LA.address(EOA.upcase.sub('0X', '0x'))
    assert_equal SMART, LA.address(LA.checksum(EOA))
  end

  def test_checksum_eip55_vectors
    %w[
      0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed
      0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359
      0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB
      0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb
    ].each { |addr| assert_equal addr, LA.checksum(addr.downcase) }
  end

  def test_rejects_invalid_addresses
    assert_raises(ArgumentError) { LA.address('0x1234') }
    assert_raises(ArgumentError) { LA.checksum(nil) }
  end

  def test_create_account_selector
    assert_equal '5fbfb9cf', LA::CREATE_ACCOUNT_SELECTOR
  end

  def test_owner_from_wrapped_signature
    assert_equal LA.checksum(EOA), LA.owner_from_signature(SMART, WRAPPED_SIGNATURE)
    assert_equal LA.checksum(EOA), LA.owner_from_signature(SMART.downcase, WRAPPED_SIGNATURE)
  end

  def test_owner_requires_create2_binding
    other = LA.address('0x51bd128eb1f801ce41910001589d41d452bd6eeb')
    assert_nil LA.owner_from_signature(other, WRAPPED_SIGNATURE)
  end

  def test_owner_requires_salt_zero_and_magic
    salted = WRAPPED_SIGNATURE.sub(EOA[2..-1] + '0' * 64, EOA[2..-1] + '0' * 63 + '1')
    refute_equal WRAPPED_SIGNATURE, salted
    assert_nil LA.owner_from_signature(SMART, salted)
    assert_nil LA.owner_from_signature(SMART, '0x' + '11' * 65)
    assert_nil LA.owner_from_signature(SMART, '0x' + LA::EIP6492_MAGIC)
  end
end

class AddressMapShapeTest < Minitest::Test
  def test_flat_and_chain_keyed_maps
    flat = { EOA => SMART }
    keyed = { '1' => flat, '11155111' => { EOA => SMART } }
    assert_equal [[EOA, SMART]], REWRITE.address_pairs(flat)
    assert_equal [[EOA, SMART], [EOA, SMART]], REWRITE.address_pairs(keyed)
  end

  def test_self_test_passes_on_real_map
    pairs = REWRITE.address_pairs(JSON.parse(File.read(MAP_PATH)))
    assert_equal pairs.size, REWRITE.self_test!(pairs)
  end

  def test_self_test_rejects_mismatch_and_empty
    assert_raises(RuntimeError) { REWRITE.self_test!([[EOA, '0x' + '1' * 40]]) }
    assert_raises(RuntimeError) { REWRITE.self_test!([[EOA, SMART.downcase.sub('a47f', 'a47e')]]) }
    assert_raises(RuntimeError) { REWRITE.self_test!([]) }
  end
end

class RewritePlanTest < Minitest::Test
  EOA2 = '0x51bd128eb1f801ce41910001589d41d452bd6eeb'
  EOA_UID = LA.checksum(EOA)
  EOA2_UID = LA.checksum(EOA2)
  PAIRS = [[EOA, SMART]].freeze

  def row(id, uid, **opts)
    { id: id, user_id: id * 10, username: "u#{id}", uid: uid, owner: nil, created_at: Time.utc(2026, 1, 1) }.merge(opts)
  end

  def statuses(plan)
    plan.map { |p| [p[:row][:id], p[:status]] }.to_h
  end

  def test_rewrites_eoa_to_checksummed_light_account
    plan = REWRITE.plan([row(1, EOA_UID)], code_for: ->(_) { '' })
    assert_equal :rewrite, plan.first[:status]
    assert_equal SMART, plan.first[:to]
  end

  def test_rewrite_is_idempotent
    done = row(1, SMART, owner: EOA)
    assert_equal({ 1 => :already }, statuses(REWRITE.plan([done], code_for: ->(_) { '' })))
  end

  def test_recases_lowercase_light_account_rows
    plan = REWRITE.plan([row(1, SMART.downcase, owner: EOA)])
    assert_equal :recase, plan.first[:status]
    assert_equal SMART, plan.first[:to]
  end

  def test_reports_duplicate_and_skips_the_smart_row
    plan = REWRITE.plan([row(1, EOA_UID), row(2, SMART)], code_for: ->(_) { '' })
    assert_equal({ 1 => :duplicate, 2 => :smart_of }, statuses(plan))
    dup = plan.first
    assert_equal 20, dup[:other][:user_id]
    assert_includes dup[:note], 'u2'
  end

  def test_duplicate_with_owner_field_on_smart_row
    plan = REWRITE.plan([row(1, EOA_UID), row(2, SMART, owner: EOA)], code_for: ->(_) { '' })
    assert_equal({ 1 => :duplicate, 2 => :already }, statuses(plan))
  end

  def test_skips_contracts_but_not_7702_eoas
    codes = { EOA_UID => LA.proxy_runtime_code, EOA2_UID => '6080604052' }
    plan = REWRITE.plan([row(1, EOA_UID), row(2, EOA2_UID)], code_for: ->(a) { codes[a] })
    assert_equal({ 1 => :light_account, 2 => :contract }, statuses(plan))

    delegated = REWRITE.plan([row(1, EOA_UID)], code_for: ->(_) { 'ef0100' + 'ab' * 20 })
    assert_equal :rewrite, delegated.first[:status]
  end

  def test_rpc_failure_skips_row
    plan = REWRITE.plan([row(1, EOA_UID)], code_for: ->(_) { nil })
    assert_equal :unknown_code, plan.first[:status]
  end

  def test_suspect_after_leaves_new_rows_for_review
    plan = REWRITE.plan(
      [row(1, EOA_UID), row(2, EOA2_UID, created_at: Time.utc(2026, 10, 16))],
      suspect_after: Time.utc(2026, 10, 15),
    )
    assert_equal({ 1 => :rewrite, 2 => :review }, statuses(plan))
  end

  def test_invalid_and_orphan_rows
    plan = REWRITE.plan([row(1, 'not-an-address'), row(2, EOA_UID, user_id: nil)])
    assert_equal({ 1 => :invalid, 2 => :orphan }, statuses(plan))
  end

  def test_lowercase_known_smart_row_without_owner_is_recased_not_rewritten
    plan = REWRITE.plan([row(1, SMART.downcase)], code_for: ->(_) { '' }, known_pairs: PAIRS)
    assert_equal :recase, plan.first[:status]
    assert_equal SMART, plan.first[:to]
    assert_equal EOA, plan.first[:owner]
  end

  def test_checksummed_known_smart_row_without_owner_is_adopted
    plan = REWRITE.plan([row(1, SMART)], code_for: ->(_) { '' }, known_pairs: PAIRS)
    assert_equal :adopt, plan.first[:status]
    assert_nil plan.first[:to]
    assert_equal EOA, plan.first[:owner]
  end

  def test_recorded_owner_is_not_rewritten
    plan = REWRITE.plan([row(1, SMART, owner: EOA)], known_pairs: PAIRS)
    assert_equal :already, plan.first[:status]
    assert_nil plan.first[:owner]
  end

  def test_unknown_lowercase_uid_is_left_for_review
    plan = REWRITE.plan([row(1, EOA2)], code_for: ->(_) { '' })
    assert_equal :review, plan.first[:status]
    assert_nil plan.first[:to]
  end

  def test_lowercase_known_eoa_is_still_rewritten
    plan = REWRITE.plan([row(1, EOA)], code_for: ->(_) { '' }, known_pairs: PAIRS)
    assert_equal :rewrite, plan.first[:status]
    assert_equal SMART, plan.first[:to]
  end

  def test_known_smart_row_next_to_its_eoa_row
    plan = REWRITE.plan([row(1, EOA_UID), row(2, SMART)], code_for: ->(_) { '' }, known_pairs: PAIRS)
    assert_equal({ 1 => :duplicate, 2 => :adopt }, statuses(plan))
  end

  def test_short_wallet_matches_display_name_format
    assert_equal '0x9ba7…7c3c', REWRITE.short_wallet(EOA)
  end
end

class DerivedRenamesTest < Minitest::Test
  EOA_UID = LA.checksum(EOA)
  SHORT_EOA = '0x9ba7…7c3c'
  SHORT_SMART = '0xa47f…88cb'

  def fields(**over)
    { name: 'Alice', username: 'alice', info_nickname: nil, info_name: nil }.merge(over)
  end

  def renames(fields, **opts)
    REWRITE.derived_renames(fields, EOA, SMART, **opts).map { |r| [r[:field], r[:to]] }.to_h
  end

  def test_full_address_name_becomes_the_light_account
    [EOA, EOA_UID, EOA.upcase.sub('0X', '0x'), " #{EOA_UID} "].each do |name|
      assert_equal({ name: SMART }, renames(fields(name: name)), name)
    end
  end

  def test_full_address_name_is_shortened_when_fresh_logins_get_the_short_form
    assert_equal({ name: SHORT_SMART }, renames(fields(name: EOA_UID), short_name: true))
  end

  def test_short_wallet_name_is_renamed_in_both_modes
    assert_equal({ name: SHORT_SMART }, renames(fields(name: SHORT_EOA)))
    assert_equal({ name: SHORT_SMART }, renames(fields(name: SHORT_EOA), short_name: true))
  end

  def test_username_cut_from_the_address_is_renamed
    assert_equal({ username: SMART[0, 20] }, renames(fields(username: EOA_UID[0, 20])))
    assert_equal({ username: SMART[0, 20] }, renames(fields(username: EOA[0, 20])))
    assert_equal({ username: SMART }, renames(fields(username: EOA_UID)))
    suggested = renames(fields(username: EOA_UID[0, 20]), username_for: ->(s) { "#{s[0, 19]}1" })
    assert_equal({ username: "#{SMART[0, 19]}1" }, suggested)
  end

  def test_info_values_holding_the_address_are_renamed
    got = renames(fields(info_nickname: EOA_UID, info_name: EOA))
    assert_equal({ info_nickname: SMART, info_name: SMART }, got)
  end

  def test_chosen_and_resolved_names_are_kept
    kept = [
      fields,
      fields(name: 'vitalik.eth', username: 'vitalik', info_nickname: 'vitalik.eth', info_name: 'vitalik.eth'),
      fields(name: 'Society Member', username: 'member'),
      fields(name: nil, username: nil),
      fields(name: '', username: ''),
      # another wallet's address, short form and username
      fields(name: RewritePlanTest::EOA2, username: RewritePlanTest::EOA2[0, 20], info_name: RewritePlanTest::EOA2),
      fields(name: '0x51bd…6eeb'),
      # too short or not hex to be a cut address; address prefix with a suffix
      fields(username: '0x9ba7'),
      fields(username: '0x9ba7_fan'),
      fields(username: "#{EOA[0, 19]}2"),
      # a name that only contains the address
      fields(name: "wallet #{EOA}"),
      fields(name: '0x9ba7...7c3c'),
    ]
    kept.each { |f| assert_empty REWRITE.derived_renames(f, EOA, SMART, short_name: true), f.inspect }
  end

  def test_renaming_is_idempotent
    before = fields(name: EOA_UID, username: EOA_UID[0, 20], info_nickname: EOA_UID, info_name: EOA_UID)
    [false, true].each do |short|
      after = before.dup
      REWRITE.derived_renames(before, EOA, SMART, short_name: short).each { |r| after[r[:field]] = r[:to] }
      assert_empty REWRITE.derived_renames(after, EOA, SMART, short_name: short)
    end
  end

  def test_unchanged_username_and_bad_addresses_give_nothing
    same = REWRITE.derived_renames(fields(username: EOA[0, 20]), EOA, SMART, username_for: ->(_) { EOA[0, 20] })
    assert_empty same
    assert_empty REWRITE.derived_renames(fields(name: EOA), EOA, 'nope')
    assert_empty REWRITE.derived_renames(fields(name: EOA), nil, SMART)
    assert_empty REWRITE.derived_renames(fields(name: EOA), EOA, EOA_UID)
  end
end

class AddressMoveTest < Minitest::Test
  EOA_UID = LA.checksum(EOA)
  PAIRS = [[EOA, SMART]].freeze

  def row(id, uid, **opts)
    { id: id, user_id: id * 10, username: "u#{id}", uid: uid, owner: nil, created_at: Time.utc(2026, 1, 1) }.merge(opts)
  end

  def move(rows, merge: false, **opts)
    REWRITE.plan(rows, **opts).map { |p| REWRITE.address_move(p, merge: merge) }
  end

  def test_rewrite_moves_from_the_eoa_to_the_light_account
    assert_equal [[EOA_UID, SMART]], move([row(1, EOA_UID)], code_for: ->(_) { '' })
  end

  def test_rows_moved_by_an_earlier_run_still_report_their_owner
    assert_equal [[EOA, SMART]], move([row(1, SMART, owner: EOA)])                      # already
    assert_equal [[EOA, SMART]], move([row(1, SMART.downcase, owner: EOA)])             # recase
    assert_equal [[EOA, SMART]], move([row(1, SMART)], known_pairs: PAIRS)              # adopt
    assert_equal [[EOA, SMART]], move([row(1, SMART.downcase)], known_pairs: PAIRS)     # recase, owner from map
  end

  def test_duplicates_move_only_when_merged
    rows = [row(1, EOA_UID), row(2, SMART)]
    assert_equal [nil, nil], move(rows, code_for: ->(_) { '' })
    assert_equal [[EOA_UID, SMART], nil], move(rows, merge: true, code_for: ->(_) { '' })
  end

  def test_skipped_rows_move_nothing
    rows = [row(1, 'not-an-address'), row(2, EOA_UID, user_id: nil), row(3, RewritePlanTest::EOA2)]
    assert_equal [nil, nil, nil], move(rows, code_for: ->(_) { '' })
  end
end

class SocietyOwnerFallbackTest < Minitest::Test
  RESOLVER = DiscourseSiwe::IdentityResolver

  def with_profiles(profiles)
    original = RESOLVER.method(:resolve)
    RESOLVER.define_singleton_method(:resolve) { |addr| profiles[addr.to_s.downcase] }
    yield
  ensure
    RESOLVER.define_singleton_method(:resolve, original)
  end

  def test_uses_smart_account_profile_when_present
    with_profiles(SMART.downcase => { badge_id: '7', name: 'S' }, EOA => { badge_id: '1', name: 'E' }) do
      assert_equal 'S', RESOLVER.resolve_with_owner(SMART, EOA)[:name]
    end
  end

  def test_falls_back_to_owner_profile
    with_profiles(EOA => { badge_id: '1', name: 'E' }) do
      assert_equal 'E', RESOLVER.resolve_with_owner(SMART, EOA)[:name]
    end
    with_profiles(SMART.downcase => { badge_id: nil, name: nil }, EOA => { badge_id: '1', name: 'E' }) do
      assert_equal 'E', RESOLVER.resolve_with_owner(SMART, EOA)[:name]
    end
  end

  def test_no_owner_or_no_profiles
    with_profiles({}) do
      assert_nil RESOLVER.resolve_with_owner(SMART, nil)
      assert_nil RESOLVER.resolve_with_owner(SMART, EOA)
    end
  end
end
