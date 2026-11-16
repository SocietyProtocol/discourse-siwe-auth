#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit tests for the smart-account transfer: the planning helpers in
# SmartAccountRewrite (transfers, verify, backup SQL) and the order of
# writes in SmartAccountTransfer, run against an in-memory forum.
# No network or Discourse needed.
#
# Run: ruby -r./test/support/pure_keccak -rtime test/smart_account_transfer_unit_test.rb

require_relative 'support/pure_keccak'
require 'json'
require 'time'
require 'minitest/autorun'
require_relative '../lib/discourse_siwe/eth_rpc'
require_relative '../lib/discourse_siwe/light_account'
require_relative '../lib/discourse_siwe/smart_account_rewrite'
require_relative '../lib/discourse_siwe/smart_account_transfer'
require_relative '../lib/discourse_siwe/smart_account_transfer_runner'

module TransferFixtures
  LA = DiscourseSiwe::LightAccount
  REWRITE = DiscourseSiwe::SmartAccountRewrite
  TRANSFER = DiscourseSiwe::SmartAccountTransfer

  EOA = '0x9ba704115f0ed3a431a025ffa0525fdd1d507c3c'
  SMART = '0xA47f4D7D2FAbDbfDCe865501ADc55a2b370c88cb'
  EOA2 = '0x51bd128eb1f801ce41910001589d41d452bd6eeb'
  SMART2 = '0x04F23204ad3f9A55338F9EBbF7805633D694C0B4'
  EOA3 = '0x2e468914660439f879721caffad710acdc0a676b'
  SMART3 = '0x79f450B82d6E05E5823efb82172E5D98bDc2ea2e'
  EOA_UID = LA.checksum(EOA)
  EOA2_UID = LA.checksum(EOA2)
  EOA3_UID = LA.checksum(EOA3)
  PAIRS = [[EOA, SMART]].freeze
  T0 = Time.utc(2026, 1, 1)
  NO_CODE = ->(_address) { '' }
end

# The parts of a Discourse forum the transfer touches, with the behaviour
# that matters: the unique provider_uid index, transactions that roll back,
# username suggestions that avoid taken names, and UserMerger as 2026.8.0
# does it (the merged user's siwe row is left with no user when the target
# has its own).
class FakeForum
  UniqueViolation = Class.new(StandardError)

  attr_reader :users, :rows, :fields, :backups, :calls, :after
  attr_accessor :fail_on, :merge_available

  def initialize
    @users = {}
    @rows = {}
    @fields = {}
    @backups = []
    @calls = []
    @after = []
    @fail_on = {}
    @merge_available = true
  end

  def add_user(id, username:, name: nil, created_at: TransferFixtures::T0, groups: [], badges: [], posts: 0)
    @users[id] = { username: username, name: name, created_at: created_at, groups: groups.dup, badges: badges.dup, posts: posts }
    @fields[id] = {}
    self
  end

  def add_row(id, user_id, uid, info: {}, extra: {}, created_at: TransferFixtures::T0)
    @rows[id] = { user_id: user_id, uid: uid, info: info.dup, extra: extra.dup, created_at: created_at }
    self
  end

  # A wallet user as the EOA login left them: uid, wallet field, a display
  # name and username cut from the address, info holding the address.
  def add_wallet_user(id, eoa_uid, short_name: false, **user)
    lower = eoa_uid.downcase
    name = short_name ? "#{lower[0..5]}…#{lower[-4..-1]}" : eoa_uid
    add_user(id, **{ username: eoa_uid[0, 20], name: name }.merge(user))
    add_row(id, id, eoa_uid, info: { 'nickname' => eoa_uid, 'name' => eoa_uid, 'image' => nil })
    @fields[id]['wallet_address'] = lower
    @fields[id]['society_resolved_at'] = '2026-01-01T00:00:00Z'
    self
  end

  # A user the Light Account login created for S.
  def add_smart_user(id, smart, owner: nil, **user)
    add_user(id, **{ username: smart[0, 20], name: smart }.merge(user))
    add_row(id, id, smart, info: { 'nickname' => smart, 'name' => smart }, extra: owner ? { 'owner_address' => owner } : {})
    @fields[id]['wallet_address'] = smart.downcase
    @fields[id]['siwe_owner_address'] = owner.downcase if owner
    self
  end

  def state
    Marshal.load(Marshal.dump([@users, @rows, @fields, @backups]))
  end

  # ---- store interface ------------------------------------------------------

  def accounts
    @rows.sort.map do |id, row|
      user = @users[row[:user_id]]
      fields = user ? @fields[row[:user_id]] : {}
      {
        id: id, user_id: user && row[:user_id], username: user && user[:username], name: user && user[:name],
        uid: row[:uid], owner: fields['siwe_owner_address'], wallet: fields['wallet_address'],
        extra_owner: row[:extra]['owner_address'], info_nickname: row[:info]['nickname'],
        info_name: row[:info]['name'], created_at: row[:created_at], user_created_at: user && user[:created_at]
      }
    end
  end

  def suggest_username(smart, free_username)
    base = smart[0, 20]
    return free_username if free_username && free_username.downcase == base.downcase
    return base unless taken?(base)

    (1..99).each do |i|
      attempt = "#{base[0, 20 - i.to_s.length]}#{i}"
      return attempt unless taken?(attempt)
    end
    nil
  end

  def transaction
    before = state
    yield
  rescue StandardError
    @users, @rows, @fields, @backups = before
    raise
  end

  def backup(run, merge_user_ids:)
    step(:backup)
    tables = TransferFixtures::REWRITE.backup_tables(run, merge_user_ids: merge_user_ids).map(&:first)
    @backups << { run: run, tables: tables, rows: Marshal.load(Marshal.dump(@rows)) }
    tables
  end

  def backup_runs
    TransferFixtures::REWRITE.backup_runs(@backups.flat_map { |b| b[:tables] })
  end

  def delete_account(id)
    step(:delete_account)
    @rows.delete(id)
  end

  def set_uid(id, uid)
    step(:set_uid)
    raise UniqueViolation, "provider_uid #{uid} is taken" if @rows.any? { |other, row| other != id && row[:uid] == uid }

    @rows.fetch(id)[:uid] = uid
  end

  def set_info(id, values)
    step(:set_info)
    @rows.fetch(id)[:info].merge!(values)
  end

  def set_fields(user_id, values)
    step(:set_fields)
    @fields.fetch(user_id).merge!(values)
  end

  def clear_fields(user_id, names)
    step(:clear_fields)
    names.each { |name| @fields.fetch(user_id).delete(name) }
  end

  def set_name(user_id, name)
    step(:set_name)
    @users.fetch(user_id)[:name] = name
  end

  def username(user_id)
    @users.fetch(user_id)[:username]
  end

  def change_username(user_id, to)
    step(:change_username)
    raise "username #{to} is taken" if taken?(to)

    @users.fetch(user_id)[:username] = to
  end

  def merge_available?
    @merge_available
  end

  def merge_users(loser_id, survivor_id)
    step(:merge_users)
    loser = @users.fetch(loser_id)
    survivor = @users.fetch(survivor_id)
    survivor[:posts] += loser[:posts]
    survivor[:groups] |= loser[:groups]
    survivor[:badges] |= loser[:badges]
    survivor[:created_at] = [survivor[:created_at], loser[:created_at]].min
    @fields[loser_id].each { |name, value| @fields[survivor_id][name] = value unless @fields[survivor_id].key?(name) }
    has_row = @rows.any? { |_, row| row[:user_id] == survivor_id }
    @rows.each_value { |row| row[:user_id] = (has_row ? nil : survivor_id) if row[:user_id] == loser_id }
    step(:merge_users_delete)
    @users.delete(loser_id)
    @fields.delete(loser_id)
  end

  private

  def taken?(username)
    @users.any? { |_, user| user[:username].downcase == username.downcase }
  end

  # Counts a call and raises when fail_on[name] says this one fails.
  def step(name)
    @calls << name
    return unless @fail_on[name]

    @fail_on[name] -= 1
    return unless @fail_on[name].zero?

    @fail_on.delete(name)
    raise "injected failure in #{name}"
  end
end

class FakeForumWithHook < FakeForum
  def after_transfer(moved_user_ids:, merged:)
    @after << { moved: moved_user_ids, merged: merged }
    ["hook saw #{moved_user_ids.size} moved"]
  end
end

module TransferHelpers
  include TransferFixtures

  def transfer(forum, **opts)
    @lines = []
    defaults = {
      store: forum, pairs: PAIRS, code_for: NO_CODE, no_login_deployed: true, run_id: 'r1',
      out: ->(line) { @lines << line },
    }
    TRANSFER.new(**defaults.merge(opts))
  end

  def output
    @lines.join("\n")
  end

  def plan_for(forum, **opts)
    REWRITE.plan(forum.accounts, **{ code_for: NO_CODE, known_pairs: PAIRS }.merge(opts))
  end
end

# ---- planner additions -------------------------------------------------------

class OwnerProofPlanTest < Minitest::Test
  include TransferHelpers

  def row(id, uid, **opts)
    { id: id, user_id: id * 10, username: "u#{id}", uid: uid, owner: nil, created_at: T0 }.merge(opts)
  end

  def test_owner_in_the_sign_in_record_adopts_the_row
    plan = REWRITE.plan([row(1, SMART2, extra_owner: EOA2_UID)], code_for: NO_CODE)
    assert_equal :adopt, plan.first[:status]
    assert_equal EOA2, plan.first[:owner]
    assert_includes plan.first[:note], 'sign-in record'
  end

  def test_sign_in_record_that_does_not_derive_the_uid_is_ignored
    plan = REWRITE.plan([row(1, EOA2_UID, extra_owner: EOA3_UID)], code_for: NO_CODE)
    assert_equal :rewrite, plan.first[:status]
    assert_equal SMART2, plan.first[:to]
  end

  def test_recorded_owner_wins_over_the_sign_in_record
    plan = REWRITE.plan([row(1, SMART2, owner: EOA2, extra_owner: EOA2_UID)])
    assert_equal :already, plan.first[:status]
    assert_nil plan.first[:owner]
  end

  def test_orphan_row_on_the_light_account_is_replaced_not_a_duplicate
    plan = REWRITE.plan([row(1, EOA2_UID), row(2, SMART2, user_id: nil, username: nil)], code_for: NO_CODE)
    assert_equal %i[rewrite orphan], plan.map { |p| p[:status] }
    assert_equal 2, plan.first[:other][:id]
    assert_includes plan.first[:note], 'orphan row 2'
  end

  def test_light_account_row_next_to_an_orphan_eoa_row_is_adopted
    plan = REWRITE.plan([row(1, EOA2_UID, user_id: nil, username: nil), row(2, SMART2)], code_for: NO_CODE)
    assert_equal %i[orphan adopt], plan.map { |p| p[:status] }
    assert_equal EOA2, plan.last[:owner]
    assert_includes plan.last[:note], 'orphan row 1'
  end

  def test_light_account_row_next_to_a_live_eoa_row_is_still_its_duplicate
    plan = REWRITE.plan([row(1, EOA2_UID), row(2, SMART2)], code_for: NO_CODE)
    assert_equal %i[duplicate smart_of], plan.map { |p| p[:status] }
  end
end

class MergePairTest < Minitest::Test
  include TransferHelpers

  def entry(a, b)
    { row: a, other: b }
  end

  def test_the_older_user_survives
    old = { id: 1, user_id: 50, user_created_at: T0 }
    new = { id: 2, user_id: 7, user_created_at: T0 + 60 }
    assert_equal({ survivor: old, loser: new }, REWRITE.merge_pair(entry(old, new)))
    assert_equal({ survivor: old, loser: new }, REWRITE.merge_pair(entry(new, old)))
  end

  def test_same_creation_time_keeps_the_lower_user_id
    a = { id: 1, user_id: 9, user_created_at: T0 }
    b = { id: 2, user_id: 4, user_created_at: T0 }
    assert_equal b, REWRITE.merge_pair(entry(a, b))[:survivor]
  end

  def test_a_user_without_a_creation_time_does_not_survive
    a = { id: 1, user_id: 1, user_created_at: nil }
    b = { id: 2, user_id: 2, user_created_at: T0 }
    assert_equal b, REWRITE.merge_pair(entry(a, b))[:survivor]
  end
end

class TransfersTest < Minitest::Test
  include TransferHelpers

  def transfers(forum, **opts)
    REWRITE.transfers(plan_for(forum), **{ username_for: ->(s, free) { forum.suggest_username(s, free) } }.merge(opts))
  end

  def test_field_changes_follow_the_login
    assert_equal(
      [{ field: :wallet_address, from: EOA2, to: SMART2.downcase }, { field: :siwe_owner_address, from: nil, to: EOA2 }],
      REWRITE.field_changes({ wallet: EOA2, owner: nil }, EOA2_UID, SMART2),
    )
    assert_empty REWRITE.field_changes({ wallet: SMART2.downcase, owner: EOA2 }, EOA2, SMART2)
    assert_equal [:siwe_owner_address], REWRITE.field_changes({ wallet: SMART2.downcase, owner: EOA2_UID }, EOA2, SMART2).map { |c| c[:field] }
  end

  def test_a_wallet_user_gets_one_transfer_with_everything_derived_from_the_address
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID)
    list = transfers(forum)
    assert_equal 1, list.size
    t = list.first
    assert_equal [1, 1, EOA2, SMART2, true], t.values_at(:account_id, :user_id, :eoa, :smart, :moved)
    assert_equal({ from: EOA2_UID, to: SMART2 }, t[:uid])
    assert_nil t[:merge]
    assert_nil t[:delete]
    assert_equal %i[wallet_address siwe_owner_address], t[:fields].map { |f| f[:field] }
    assert_equal({ name: SMART2, username: SMART2[0, 20], info_nickname: SMART2, info_name: SMART2 },
                 t[:renames].map { |r| [r[:field], r[:to]] }.to_h)
    assert REWRITE.changes?(t)
  end

  def test_an_account_that_is_fully_moved_has_nothing_to_write
    forum = FakeForum.new.add_smart_user(1, SMART2, owner: EOA2)
    list = transfers(forum)
    assert_equal [:already], list.map { |t| t[:status] }
    refute REWRITE.changes?(list.first)
    refute list.first[:moved]
  end

  def test_a_moved_account_with_stale_fields_and_names_is_still_fixed
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID)
    forum.rows[1][:uid] = SMART2
    forum.fields[1]['siwe_owner_address'] = EOA2
    t = transfers(forum).first
    assert_equal :already, t[:status]
    assert_nil t[:uid]
    assert_equal [:wallet_address], t[:fields].map { |f| f[:field] }
    assert_equal %i[name username info_nickname info_name], t[:renames].map { |r| r[:field] }
  end

  def test_duplicates_are_not_transferred_without_merge
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID).add_smart_user(2, SMART2, created_at: T0 + 60)
    assert_empty transfers(forum)
  end

  # Reviewer finding 1: one transfer per surviving account, never one per
  # plan row, also when both rows of the pair have a move of their own.
  def test_a_merged_pair_is_one_transfer_on_the_surviving_account
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID).add_smart_user(2, SMART2, owner: EOA2, created_at: T0 + 60)
    assert_equal %i[duplicate already], plan_for(forum).map { |p| p[:status] }
    list = transfers(forum, merge: true)
    assert_equal [1], list.map { |t| t[:account_id] }
    assert_equal({ user_id: 2, username: SMART2[0, 20], account_id: 2 }, list.first[:merge])
    assert_equal 2, list.first[:delete]
    assert_equal({ from: EOA2_UID, to: SMART2 }, list.first[:uid])
  end

  def test_the_light_account_user_survives_when_it_is_the_older_one
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID, created_at: T0 + 60).add_smart_user(2, SMART2, owner: EOA2)
    list = transfers(forum, merge: true)
    assert_equal [2], list.map { |t| t[:account_id] }
    t = list.first
    assert_equal 2, t[:user_id]
    assert_nil t[:uid]
    assert_equal({ user_id: 1, username: EOA2_UID[0, 20], account_id: 1 }, t[:merge])
    assert_equal 1, t[:delete]
    assert_empty t[:fields]
    assert_empty t[:renames]
  end

  # Reviewer finding 2, planning side: the name the duplicate holds is free
  # for the survivor once the duplicate is merged away.
  def test_a_merged_survivor_is_planned_onto_the_plain_username
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID).add_smart_user(2, SMART2, created_at: T0 + 60)
    username = transfers(forum, merge: true).first[:renames].find { |r| r[:field] == :username }
    assert_equal SMART2[0, 20], username[:to]
  end

  def test_a_name_held_by_someone_else_is_still_suffixed
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID).add_user(9, username: SMART2[0, 20].downcase)
    username = transfers(forum).first[:renames].find { |r| r[:field] == :username }
    assert_equal "#{SMART2[0, 19]}1", username[:to]
  end

  def test_keep_usernames_drops_only_the_username
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID)
    assert_equal %i[name info_nickname info_name], transfers(forum, keep_usernames: true).first[:renames].map { |r| r[:field] }
  end

  def test_an_orphan_row_on_the_light_account_is_deleted_by_the_rewrite
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID).add_row(5, nil, SMART2)
    t = transfers(forum).first
    assert_equal 5, t[:delete]
    assert_nil t[:merge]
  end

  def test_skipped_rows_have_no_transfer
    forum = FakeForum.new.add_user(1, username: 'safe').add_row(1, 1, EOA2_UID).add_row(2, nil, EOA3_UID)
    plan = REWRITE.plan(forum.accounts, code_for: ->(_) { '6080' })
    assert_equal %i[contract orphan], plan.map { |p| p[:status] }
    assert_empty REWRITE.transfers(plan)
  end
end

class VerifyTest < Minitest::Test
  include TransferHelpers

  def verify(forum, plan_opts: {}, merge: false, **opts)
    plan = plan_for(forum, **plan_opts)
    REWRITE.verify(plan, REWRITE.transfers(plan, merge: merge), **opts)
  end

  def ids(list)
    list.map { |item| item[:row][:id] }
  end

  def test_a_plan_with_only_writes_passes_before_and_fails_after_an_apply
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID).add_smart_user(2, SMART3, owner: EOA3)
    before = verify(forum)
    assert before[:ok]
    assert_equal [[1], [2]], [ids(before[:pending]), ids(before[:done])]

    after = verify(forum, applied: true)
    refute after[:ok]
    assert_empty after[:unresolved]
  end

  def test_recognised_skips_never_fail
    forum = FakeForum.new.add_user(1, username: 'safe').add_row(1, 1, EOA2_UID)
                      .add_row(2, nil, EOA3_UID).add_user(3, username: 'odd').add_row(3, 3, 'not-an-address')
    result = verify(forum, plan_opts: { code_for: ->(_) { '6080' } }, applied: true)
    assert result[:ok]
    assert_equal [1, 2, 3], ids(result[:skipped])
    assert_equal ['contract wallet, signs in as itself', 'row has no user', 'uid is not an address'],
                 result[:skipped].map { |i| i[:reason] }
  end

  def test_a_deployed_light_account_with_unknown_owner_is_a_recognised_skip
    forum = FakeForum.new.add_user(1, username: 'la').add_row(1, 1, SMART2)
    result = verify(forum, plan_opts: { code_for: ->(_) { LA.proxy_runtime_code } }, applied: true)
    assert result[:ok]
    assert_equal [:light_account], result[:skipped].map { |i| i[:status] }
  end

  def test_unmerged_duplicates_are_unresolved_on_both_rows
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID).add_smart_user(2, SMART2, created_at: T0 + 60)
    result = verify(forum)
    refute result[:ok]
    assert_equal [1, 2], ids(result[:unresolved])
    assert_includes result[:unresolved].first[:reason], 'MERGE_DUPLICATES=1'
    assert_includes result[:unresolved].last[:reason], 'not merged'

    merged = verify(forum, merge: true)
    assert merged[:ok]
    assert_equal [1, 2], ids(merged[:pending])
  end

  def test_review_rows_fail_until_the_operator_accepts_them
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID)
    forum.rows[1][:created_at] = T0 + 3600
    opts = { plan_opts: { suspect_after: T0 }, applied: true }
    result = verify(forum, **opts)
    refute result[:ok]
    assert_includes result[:unresolved].first[:reason], 'REVIEWED_ROWS'

    accepted = verify(forum, **opts.merge(reviewed: [1]))
    assert accepted[:ok]
    assert_equal [1], ids(accepted[:accepted])
    refute verify(forum, **opts.merge(reviewed: [2]))[:ok]
  end

  def test_an_rpc_failure_is_unresolved
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID)
    result = verify(forum, plan_opts: { code_for: ->(_) {} })
    refute result[:ok]
    assert_includes result[:unresolved].first[:reason], 'eth_getCode failed'
  end
end

class BackupSqlTest < Minitest::Test
  include TransferHelpers

  def test_three_tables_and_two_more_for_merged_users
    plain = REWRITE.backup_tables('20261111120000')
    assert_equal %w[siwe_backup_20261111120000_accounts siwe_backup_20261111120000_fields siwe_backup_20261111120000_users],
                 plain.map(&:first)
    assert_includes plain[0][1], "provider_name = 'siwe'"
    refute_includes plain[0][1], 'user_id IS NOT NULL' # orphan rows are backed up too

    merged = REWRITE.backup_tables('r1', merge_user_ids: [7, 3, 7])
    assert_equal %w[siwe_backup_r1_group_users siwe_backup_r1_user_badges], merged.map(&:first)[3..-1]
    assert_includes merged[3][1], 'user_id IN (3, 7)'
  end

  def test_only_integer_ids_and_plain_run_ids_reach_the_sql
    assert_raises(ArgumentError) { REWRITE.backup_tables('r1', merge_user_ids: ['1); DROP TABLE users; --']) }
    ['', 'r1; DROP', 'R1', 'a' * 25, nil].each do |run|
      assert_raises(ArgumentError) { REWRITE.backup_tables(run) }
      assert_raises(ArgumentError) { REWRITE.restore_sql(run) }
    end
  end

  def test_restore_reads_only_the_backup_of_its_run_and_matches_fields_by_user_and_name
    sql = REWRITE.restore_sql('r1')
    assert_equal %w[siwe_backup_r1_accounts siwe_backup_r1_fields siwe_backup_r1_users], sql.scan(/siwe_backup_\w+/).uniq.sort
    assert sql.start_with?("BEGIN;\n")
    assert sql.end_with?("COMMIT;\n")
    # save_custom_fields replaces rows, so their ids change: never join on id.
    refute_match(/f\.id\s*=\s*b\.id/, sql)
    REWRITE::TRANSFER_FIELDS.each { |name| assert_includes sql, "'#{name}'" }
    refute_match(/username/, sql)
  end
end

# ---- the transfer against the in-memory forum --------------------------------

class TransferDryRunTest < Minitest::Test
  include TransferHelpers

  def test_a_dry_run_writes_nothing_and_prints_the_plan_per_user
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID).add_wallet_user(2, EOA3_UID, short_name: true)
    before = forum.state
    result = transfer(forum).run

    assert_equal [:dry_run, true], result.values_at(:status, :ok)
    assert_equal before, forum.state
    assert_empty forum.calls
    assert_includes output, "user 1 (#{EOA2_UID[0, 20]}), account row 1, rewrite:"
    assert_includes output, "  provider_uid        #{EOA2_UID} -> #{SMART2}"
    assert_includes output, "  wallet_address      #{EOA2} -> #{SMART2.downcase}"
    assert_includes output, "  siwe_owner_address  (none) -> #{EOA2}"
    assert_includes output, '  name                0x2e46…676b -> 0x79f4…ea2e'
    assert_includes output, '2 users change: 2 provider_uid, 4 custom fields, 2 display names, 2 usernames, 4 info values, 0 merges, 0 orphan rows replaced'
    assert_includes output, 'AFTER AN APPLY: 2 on their Light Account, 0 recognised skips, 0 accepted reviews, 0 unresolved'
    assert_includes output, 'DRY RUN: nothing written.'
  end

  def test_a_dry_run_says_when_an_apply_would_fail_verification
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID).add_smart_user(2, SMART2, created_at: T0 + 60)
    result = transfer(forum).run
    assert result[:ok]
    refute result[:verification][:ok]
    assert_includes output, 'UNRESOLVED row 1 user 1'
    assert_includes output, 'would FAIL verification'
  end

  def test_a_dry_run_counts_a_pair_to_merge_as_one_account
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID).add_smart_user(2, SMART2, created_at: T0 + 60)
                      .add_wallet_user(3, EOA3_UID)
    before = forum.state
    result = transfer(forum, merge: true).run
    assert result[:verification][:ok]
    assert_equal before, forum.state
    assert_includes output, 'AFTER AN APPLY: 2 on their Light Account, 0 recognised skips, 0 accepted reviews, 0 unresolved'
    assert_includes output, "  merge               user 2 (#{SMART2[0, 20]}) into this user"
  end

  def test_the_address_map_is_checked_first
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID)
    assert_raises(RuntimeError) { transfer(forum, pairs: [[EOA, SMART2]], apply: true).run }
    assert_raises(RuntimeError) { transfer(forum, pairs: [], apply: true).run }
    assert_empty forum.calls
  end
end

class TransferApplyTest < Minitest::Test
  include TransferHelpers

  def test_apply_moves_everything_that_identifies_the_user_by_address
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID, groups: %w[members], badges: [7], posts: 3)
    result = transfer(forum, apply: true).run

    assert_equal [:applied, true], result.values_at(:status, :ok)
    assert_equal SMART2, forum.rows[1][:uid]
    assert_equal({ 'wallet_address' => SMART2.downcase, 'siwe_owner_address' => EOA2 }, forum.fields[1])
    user = forum.users[1]
    assert_equal [SMART2, SMART2[0, 20]], user.values_at(:name, :username)
    assert_equal [%w[members], [7], 3], user.values_at(:groups, :badges, :posts)
    assert_equal({ 'nickname' => SMART2, 'name' => SMART2, 'image' => nil }, forum.rows[1][:info])
    assert_equal({ uids: 1, fields: 2, names: 1, info: 2, usernames: 1 }, result[:counts])
    assert_equal %w[siwe_backup_r1_accounts siwe_backup_r1_fields siwe_backup_r1_users], result[:backup]
    assert_includes output, 'VERIFICATION: 1 on their Light Account, 0 recognised skips, 0 accepted reviews, 0 unresolved'
    assert_includes output, 'UPDATE user_associated_accounts a SET provider_uid = b.provider_uid'
  end

  def test_the_backup_is_taken_before_the_first_write
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID)
    transfer(forum, apply: true).run
    assert_equal :backup, forum.calls.first
    assert_equal EOA2_UID, forum.backups.first[:rows][1][:uid]
  end

  def test_short_names_follow_the_site_setting
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID).add_wallet_user(2, EOA3_UID, short_name: true)
    transfer(forum, apply: true, short_name: true).run
    assert_equal %w[0x04f2…c0b4 0x79f4…ea2e], [forum.users[1][:name], forum.users[2][:name]]
  end

  def test_a_second_apply_writes_nothing_and_takes_no_backup
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID).add_wallet_user(2, EOA3_UID)
    transfer(forum, apply: true).run
    after_first = forum.state
    calls = forum.calls.size

    result = transfer(forum, apply: true, run_id: 'r2').run
    assert_equal [:applied, true], result.values_at(:status, :ok)
    assert_equal after_first, forum.state
    assert_equal calls, forum.calls.size
    assert_empty result[:backup]
    assert_empty result[:counts]
    assert_includes output, 'Nothing to write'
  end

  def test_an_apply_is_refused_without_the_login_confirmation
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID)
    before = forum.state
    result = transfer(forum, apply: true, no_login_deployed: false).run
    assert_equal [:refused, false], result.values_at(:status, :ok)
    assert_equal before, forum.state
    assert_includes output, 'SUSPECT_AFTER'

    assert transfer(forum, apply: true, no_login_deployed: false, suspect_after: T0 + 60).run[:ok]
  end

  def test_rows_created_after_suspect_after_fail_verification_until_accepted
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID).add_wallet_user(2, EOA3_UID)
    forum.rows[2][:created_at] = T0 + 3600
    opts = { apply: true, no_login_deployed: false, suspect_after: T0 + 60 }

    result = transfer(forum, **opts).run
    assert_equal [:verification_failed, false], result.values_at(:status, :ok)
    assert_equal [SMART2, EOA3_UID], [forum.rows[1][:uid], forum.rows[2][:uid]]
    assert_includes output, 'VERIFICATION FAILED'

    assert transfer(forum, **opts.merge(reviewed: [2], run_id: 'r2')).run[:ok]
    assert_equal EOA3_UID, forum.rows[2][:uid]
  end

  def test_contract_wallets_are_left_and_do_not_fail
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID).add_wallet_user(2, EOA3_UID)
    codes = { EOA2_UID => '', EOA3_UID => '6080' }
    result = transfer(forum, apply: true, code_for: ->(a) { codes[a] }).run
    assert result[:ok]
    assert_equal EOA3_UID, forum.rows[2][:uid]
    assert_includes output, "skip row 2 user 2 (#{EOA3_UID[0, 20]}) #{EOA3_UID} [contract]"
  end

  def test_the_code_of_an_address_is_asked_once
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID).add_wallet_user(2, EOA3_UID)
    asked = Hash.new(0)
    codes = { EOA2_UID => '', EOA3_UID => '6080' }
    transfer(forum, apply: true, code_for: ->(a) { asked[a] += 1; codes[a] }).run
    assert_equal({ EOA2_UID => 1, EOA3_UID => 1 }, asked)
  end

  def test_a_failure_in_the_first_transaction_rolls_everything_back
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID).add_wallet_user(2, EOA3_UID)
    before = forum.state
    forum.fail_on = { set_name: 2 }
    job = transfer(forum, apply: true)
    error = assert_raises(RuntimeError) { job.run }
    assert_includes error.message, 'injected failure in set_name'
    assert_equal before, forum.state
    assert_empty forum.backups
    assert_empty job.counts
    assert_includes output, 'rolled back'

    assert transfer(forum, apply: true).run[:ok]
  end

  def test_an_orphan_row_holding_the_light_account_is_replaced
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID).add_row(5, nil, SMART2)
    result = transfer(forum, apply: true).run
    assert result[:ok]
    assert_equal [1], forum.rows.keys
    assert_equal SMART2, forum.rows[1][:uid]
    assert_includes output, '0 duplicate users merged, 1 orphan rows replaced'
  end

  def test_the_store_hook_gets_the_moved_and_merged_users
    forum = FakeForumWithHook.new.add_wallet_user(1, EOA2_UID).add_smart_user(2, SMART2, created_at: T0 + 60)
                             .add_wallet_user(3, EOA3_UID).add_smart_user(4, SMART, owner: EOA)
    transfer(forum, apply: true, merge: true, full_backup_taken: true).run
    assert_equal [{ moved: [3, 1], merged: { 2 => 1 } }], forum.after # merges are written after the rest
    assert_includes output, 'hook saw 2 moved'
  end

  def test_the_store_hook_still_runs_for_what_was_written_before_a_failed_merge
    forum = FakeForumWithHook.new.add_wallet_user(1, EOA2_UID).add_smart_user(2, SMART2, created_at: T0 + 60)
                             .add_wallet_user(3, EOA3_UID)
    forum.fail_on = { merge_users: 1 }
    assert_raises(RuntimeError) { transfer(forum, apply: true, merge: true, full_backup_taken: true).run }
    assert_equal [{ moved: [3], merged: {} }], forum.after

    transfer(forum, apply: true, merge: true, full_backup_taken: true, run_id: 'r2').run
    assert_equal({ moved: [1], merged: { 2 => 1 } }, forum.after.last)
  end

  def test_a_failing_store_hook_is_reported_and_does_not_fail_the_transfer
    forum = Class.new(FakeForum) do
      def after_transfer(moved_user_ids:, merged:)
        raise 'plugin store is down'
      end
    end.new.add_wallet_user(1, EOA2_UID)
    result = transfer(forum, apply: true).run
    assert result[:ok]
    assert_includes output, 'WARNING: the store\'s after_transfer step failed (RuntimeError: plugin store is down)'
  end

  def test_nothing_written_means_no_hook_call
    forum = FakeForumWithHook.new.add_smart_user(1, SMART2, owner: EOA2)
    assert transfer(forum, apply: true).run[:ok]
    assert_empty forum.after
  end

  def test_society_lookup_is_marked_stale_only_for_accounts_moved_now
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID).add_smart_user(2, SMART3, owner: EOA3)
    forum.fields[2]['society_resolved_at'] = '2026-02-02T00:00:00Z'
    forum.fields[2]['wallet_address'] = EOA3 # stale field on an account that already moved
    transfer(forum, apply: true).run
    refute forum.fields[1].key?('society_resolved_at')
    assert_equal '2026-02-02T00:00:00Z', forum.fields[2]['society_resolved_at']
    assert_equal SMART3.downcase, forum.fields[2]['wallet_address']
  end
end

class TransferMergeTest < Minitest::Test
  include TransferHelpers

  MERGE = { apply: true, merge: true, full_backup_taken: true }.freeze

  def duplicate_forum
    FakeForum.new
             .add_wallet_user(1, EOA2_UID, groups: %w[members], badges: [7], posts: 3)
             .add_smart_user(2, SMART2, owner: EOA2, created_at: T0 + 60, groups: %w[holders], badges: [7, 9], posts: 2)
  end

  def test_without_merge_duplicates_are_left_and_verification_fails
    forum = duplicate_forum.add_wallet_user(3, EOA3_UID)
    result = transfer(forum, apply: true).run
    assert_equal [:verification_failed, false], result.values_at(:status, :ok)
    assert_equal [EOA2_UID, SMART2, SMART3], forum.rows.values.map { |r| r[:uid] }
    assert_equal [1, 2, 3], forum.users.keys
    refute_includes forum.calls, :merge_users
    assert_includes output, 'UNRESOLVED row 1 user 1'
  end

  def test_merges_are_refused_without_a_full_backup_or_without_user_merger
    forum = duplicate_forum
    before = forum.state
    result = transfer(forum, apply: true, merge: true).run
    assert_equal :refused, result[:status]
    assert_includes output, 'FULL_BACKUP_TAKEN=1'

    forum.merge_available = false
    assert_equal :refused, transfer(forum, **MERGE).run[:status]
    assert_includes output, 'UserMerger is not available'
    assert_equal before, forum.state
  end

  def test_a_merged_pair_ends_as_one_user_with_everything
    forum = duplicate_forum
    result = transfer(forum, **MERGE).run

    assert_equal [:applied, true], result.values_at(:status, :ok)
    assert_equal [1], forum.users.keys
    assert_equal({ 1 => SMART2 }, forum.rows.map { |id, r| [id, r[:uid]] }.to_h)
    user = forum.users[1]
    assert_equal [5, %w[members holders], [7, 9]], user.values_at(:posts, :groups, :badges)
    assert_equal SMART2.downcase, forum.fields[1]['wallet_address']
    assert_equal EOA2, forum.fields[1]['siwe_owner_address']
    assert_equal %w[siwe_backup_r1_accounts siwe_backup_r1_fields siwe_backup_r1_users siwe_backup_r1_group_users siwe_backup_r1_user_badges],
                 result[:backup]
    assert_includes output, "merged user 2 (#{SMART2[0, 20]}) into 1 (#{EOA2_UID[0, 20]})"
  end

  # Reviewer finding 2: the survivor takes the plain name its duplicate held,
  # because the name is suggested after the merge.
  def test_the_survivor_gets_the_unsuffixed_username
    forum = duplicate_forum
    transfer(forum, **MERGE).run
    assert_equal SMART2[0, 20], forum.users[1][:username]
    assert_operator forum.calls.index(:change_username), :>, forum.calls.index(:merge_users_delete)
  end

  # Reviewer findings 1 and 3: each user and each written value counted once.
  def test_counts_match_what_was_written
    forum = duplicate_forum.add_wallet_user(3, EOA3_UID)
    result = transfer(forum, **MERGE).run
    assert_equal({ uids: 2, fields: 4, names: 2, info: 4, usernames: 2, merged: 1, rows_deleted: 1 }, result[:counts])
    assert_includes output, '2 users change: 2 provider_uid, 4 custom fields, 2 display names, 2 usernames, 4 info values, 1 merges, 0 orphan rows replaced'
    assert_includes output, 'APPLIED: 2 provider_uid, 4 custom fields, 2 display names, 4 info values and 2 usernames written; ' \
                            '1 duplicate users merged, 0 orphan rows replaced.'
    assert_equal 1, output.scan(/^user 1 \(/).size
    assert_equal 0, output.scan(/^user 2 \(/).size
  end

  def test_the_older_light_account_user_survives_and_is_listed_once
    forum = FakeForum.new
                     .add_wallet_user(1, EOA2_UID, created_at: T0 + 60, posts: 1)
                     .add_smart_user(2, SMART2, owner: EOA2, posts: 4)
    result = transfer(forum, **MERGE).run

    assert result[:ok]
    assert_equal [2], forum.users.keys
    assert_equal({ 2 => SMART2 }, forum.rows.map { |id, r| [id, r[:uid]] }.to_h)
    assert_equal 5, forum.users[2][:posts]
    assert_equal SMART2[0, 20], forum.users[2][:username]
    assert_equal({ merged: 1, rows_deleted: 1 }, result[:counts])
    assert_equal 1, output.scan(/^user 2 \(/).size
    assert_equal 0, output.scan(/^user 1 \(/).size
  end

  def test_a_duplicate_without_a_recorded_owner_gets_the_owner_from_the_merge
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID, created_at: T0 + 60).add_smart_user(2, SMART2)
    assert_equal %i[duplicate smart_of], plan_for(forum).map { |p| p[:status] }
    assert transfer(forum, **MERGE).run[:ok]
    assert_equal EOA2, forum.fields[2]['siwe_owner_address']
    assert_equal [2], forum.users.keys
  end

  def test_a_failure_after_the_merge_is_finished_by_the_next_run
    forum = duplicate_forum
    forum.fail_on = { set_uid: 1 }
    assert_raises(RuntimeError) { transfer(forum, **MERGE).run }
    assert_includes output, 'FAILED writing the account of user 1 after its merge'
    assert_equal [1], forum.users.keys
    assert_equal [EOA2_UID, SMART2], forum.rows.values.map { |r| r[:uid] } # the delete was rolled back with the uid
    assert_nil forum.rows[2][:user_id]

    result = transfer(forum, **MERGE.merge(run_id: 'r2')).run
    assert result[:ok]
    assert_equal({ 1 => SMART2 }, forum.rows.map { |id, r| [id, r[:uid]] }.to_h)
    assert_equal SMART2[0, 20], forum.users[1][:username]
  end

  def test_a_second_merge_run_writes_nothing
    forum = duplicate_forum
    transfer(forum, **MERGE).run
    after_first = forum.state
    result = transfer(forum, **MERGE.merge(run_id: 'r2')).run
    assert result[:ok]
    assert_equal after_first, forum.state
    assert_empty result[:counts]
  end

  def test_a_merge_that_fails_before_it_starts_is_retried_by_the_next_run
    forum = duplicate_forum.add_wallet_user(3, EOA3_UID)
    forum.fail_on = { merge_users: 1 }
    assert_raises(RuntimeError) { transfer(forum, **MERGE).run }
    assert_includes output, 'FAILED merging user 2'
    # the first transaction is committed, the pair is untouched
    assert_equal [EOA2_UID, SMART2, SMART3], forum.rows.values.map { |r| r[:uid] }
    assert_equal 1, forum.backups.size

    result = transfer(forum, **MERGE.merge(run_id: 'r2')).run
    assert result[:ok]
    assert_equal [1, 3], forum.users.keys
    assert_equal SMART2, forum.rows[1][:uid]
  end

  # UserMerger detaches the duplicate's siwe row before it deletes the user.
  # If it dies in between, the next run finds an orphan row on S.
  def test_a_merge_that_fails_half_way_is_finished_by_the_next_run
    forum = duplicate_forum
    forum.fail_on = { merge_users_delete: 1 }
    assert_raises(RuntimeError) { transfer(forum, **MERGE).run }
    assert_nil forum.rows[2][:user_id]
    assert_equal EOA2_UID, forum.rows[1][:uid]

    result = transfer(forum, **MERGE.merge(run_id: 'r2')).run
    assert result[:ok]
    assert_equal({ 1 => SMART2 }, forum.rows.map { |id, r| [id, r[:uid]] }.to_h)
    assert_equal 5, forum.users[1][:posts]
    assert_equal [1, 2], forum.users.keys # the half-merged user is left for an admin
  end
end

class TransferUsernameTest < Minitest::Test
  include TransferHelpers

  # A store whose suggestion at apply time is the name the user already has.
  class SameNameForum < FakeForum
    def suggest_username(smart, free_username)
      @suggested = (@suggested || 0) + 1
      @suggested > 1 ? free_username : super
    end
  end

  # Reviewer finding 3: a username that is not changed is not counted as a
  # name or info value.
  def test_a_skipped_username_is_counted_as_skipped
    forum = SameNameForum.new.add_wallet_user(1, EOA2_UID)
    result = transfer(forum, apply: true).run
    assert_equal({ uids: 1, fields: 2, names: 1, info: 2, usernames_skipped: 1 }, result[:counts])
    assert_equal EOA2_UID[0, 20], forum.users[1][:username]
    refute_includes forum.calls, :change_username
    assert_includes output, '1 display names, 2 info values and 0 usernames written (1 usernames left as they were)'
  end

  def test_keep_usernames_leaves_them_and_still_verifies
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID)
    result = transfer(forum, apply: true, keep_usernames: true).run
    assert result[:ok]
    assert_equal EOA2_UID[0, 20], forum.users[1][:username]
    assert_equal SMART2, forum.users[1][:name]
    assert_includes output, 'KEEP_USERNAMES=1'
  end

  def test_a_failed_username_change_is_retried_by_the_next_run
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID)
    forum.fail_on = { change_username: 1 }
    assert_raises(RuntimeError) { transfer(forum, apply: true).run }
    assert_equal [SMART2, EOA2_UID[0, 20]], [forum.rows[1][:uid], forum.users[1][:username]]

    result = transfer(forum, apply: true, run_id: 'r2').run
    assert result[:ok]
    assert_equal SMART2[0, 20], forum.users[1][:username]
    assert_equal({ usernames: 1 }, result[:counts])
  end

  def test_chosen_names_are_never_touched
    forum = FakeForum.new.add_user(1, username: 'alice', name: 'Alice')
                      .add_row(1, 1, EOA2_UID, info: { 'nickname' => 'alice.eth', 'name' => 'alice.eth' })
    forum.fields[1]['wallet_address'] = EOA2
    result = transfer(forum, apply: true).run
    assert result[:ok]
    assert_equal %w[alice Alice], forum.users[1].values_at(:username, :name)
    assert_equal({ 'nickname' => 'alice.eth', 'name' => 'alice.eth' }, forum.rows[1][:info])
    assert_equal({ uids: 1, fields: 2 }, result[:counts])
  end
end

class TransferVerifyOnlyTest < Minitest::Test
  include TransferHelpers

  def test_verify_is_read_only_and_fails_on_an_untransferred_forum
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID)
    before = forum.state
    result = transfer(forum).verify
    assert_equal [:verification_failed, false], result.values_at(:status, :ok)
    assert_equal before, forum.state
    assert_empty forum.calls
    assert_includes output, 'UNRESOLVED row 1 user 1'
    assert_includes output, 'still to write: provider_uid, wallet_address, siwe_owner_address, name, username, info_nickname, info_name'
  end

  def test_verify_passes_after_the_transfer
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID).add_wallet_user(2, EOA3_UID)
    transfer(forum, apply: true).run
    result = transfer(forum).verify
    assert_equal [:verified, true], result.values_at(:status, :ok)
  end
end

# Environment variables -> options. The Discourse store is replaced by the
# in-memory forum; SmartAccountTransferRunner::Store needs a live Discourse.
# Two users on one address in different case: the first rewrite stored S
# lowercase, and the login of that build then made a second user on the
# checksummed S. provider_uid is unique case-sensitively, so both rows exist.
class SharedAddressTest < Minitest::Test
  include TransferHelpers

  MERGE = { apply: true, merge: true, full_backup_taken: true }.freeze

  # User 1: the original member, moved to lowercase S by the first rewrite.
  # User 2: created by a later sign-in as checksummed S.
  def case_pair_forum(second_created_at: T0 + 60)
    forum = FakeForum.new
    forum.add_user(1, username: EOA_UID[0, 20], name: EOA_UID, posts: 4, groups: %w[members])
    forum.add_row(1, 1, SMART.downcase, info: { 'nickname' => EOA_UID, 'name' => EOA_UID })
    forum.fields[1]['wallet_address'] = SMART.downcase
    forum.add_smart_user(2, SMART, created_at: second_created_at, posts: 1, badges: %w[og])
  end

  def test_the_same_light_account_in_two_cases_is_a_duplicate_not_two_moved_accounts
    plan = plan_for(case_pair_forum)
    assert_equal %i[duplicate adopt], plan.map { |p| p[:status] }
    assert_equal SMART, plan[0][:to]
    assert_equal EOA, plan[0][:eoa]
    assert_equal 2, plan[0][:other][:id]
  end

  def test_the_dry_run_says_the_apply_would_fail_and_the_apply_does_not_hit_the_unique_index
    forum = case_pair_forum
    result = transfer(forum).run
    assert_equal 1, result[:verification][:unresolved].size
    assert_includes output, 'An apply with these options would FAIL verification'
    assert_includes output, 'merge the two with MERGE_DUPLICATES=1'

    result = transfer(forum, apply: true).run
    assert_equal :verification_failed, result[:status]
    assert_equal [SMART.downcase, SMART], forum.rows.values.map { |r| r[:uid] }
    assert_equal EOA, forum.fields[2]['siwe_owner_address'] # the other row is still completed
  end

  def test_the_pair_is_merged_onto_the_older_user
    forum = case_pair_forum
    result = transfer(forum, **MERGE).run
    assert result[:ok], output
    assert_equal [1], forum.users.keys
    assert_equal({ 1 => SMART }, forum.rows.map { |id, r| [id, r[:uid]] }.to_h)
    assert_equal SMART.downcase, forum.fields[1]['wallet_address']
    assert_equal EOA, forum.fields[1]['siwe_owner_address']
    assert_equal 5, forum.users[1][:posts]
    assert_equal %w[members], forum.users[1][:groups]
    assert_equal %w[og], forum.users[1][:badges]
    assert_equal SMART[0, 20], forum.users[1][:username]
    assert_equal SMART, forum.users[1][:name]
    assert_equal 1, result[:counts][:merged]

    after = forum.state
    assert transfer(forum, **MERGE.merge(run_id: 'r2')).run[:ok]
    assert_equal after, forum.state
  end

  def test_the_checksummed_user_survives_when_it_is_the_older_one
    forum = case_pair_forum(second_created_at: T0 - 60)
    result = transfer(forum, **MERGE).run
    assert result[:ok], output
    assert_equal [2], forum.users.keys
    assert_equal({ 2 => SMART }, forum.rows.map { |id, r| [id, r[:uid]] }.to_h)
    assert_equal EOA, forum.fields[2]['siwe_owner_address']
    assert_equal 5, forum.users[2][:posts]
  end

  def test_the_same_wallet_in_two_cases_is_one_rewrite_and_one_duplicate
    forum = FakeForum.new.add_wallet_user(1, EOA_UID, posts: 2)
    forum.add_user(2, username: 'second', name: 'Second', created_at: T0 + 60, posts: 3)
    forum.add_row(2, 2, EOA)
    assert_equal %i[duplicate rewrite], plan_for(forum).map { |p| p[:status] }

    result = transfer(forum, apply: true).run
    assert_equal :verification_failed, result[:status]
    assert_equal [EOA_UID, SMART], forum.rows.values.map { |r| r[:uid] }

    result = transfer(forum, **MERGE.merge(run_id: 'r2')).run
    assert result[:ok], output
    assert_equal [1], forum.users.keys
    assert_equal({ 1 => SMART }, forum.rows.map { |id, r| [id, r[:uid]] }.to_h)
    assert_equal 5, forum.users[1][:posts]
  end

  def test_three_users_on_one_address_are_a_conflict_and_nothing_of_them_is_written
    forum = case_pair_forum.add_wallet_user(3, EOA_UID, created_at: T0 - 60)
    forum.add_wallet_user(4, EOA2_UID)
    assert_equal %i[conflict conflict conflict rewrite], plan_for(forum).map { |p| p[:status] }

    before = forum.rows.values.first(3).map { |r| r[:uid] }
    result = transfer(forum, **MERGE).run
    assert_equal :verification_failed, result[:status]
    assert_equal 3, result[:verification][:unresolved].size
    assert_includes output, "shares #{SMART} with user"
    assert_includes output, 'merge these users in the admin UI'
    assert_equal before, forum.rows.values.first(3).map { |r| r[:uid] }
    assert_equal [1, 2, 3, 4], forum.users.keys
    assert_equal SMART2, forum.rows[4][:uid] # the others are still transferred
  end

  def test_a_pair_with_no_proven_owner_is_a_conflict
    rows = [
      { id: 1, user_id: 1, username: 'a', uid: SMART2, owner: nil, created_at: T0 },
      { id: 2, user_id: 2, username: 'b', uid: SMART2.downcase, owner: nil, created_at: T0 },
    ]
    plan = REWRITE.plan(rows, code_for: ->(_) { LA.proxy_runtime_code }, known_pairs: PAIRS)
    assert_equal %i[conflict conflict], plan.map { |p| p[:status] }
    refute REWRITE.verify(plan, REWRITE.transfers(plan, merge: true))[:ok]
  end

  def test_a_recase_replaces_an_orphan_row_that_holds_the_checksummed_uid
    forum = FakeForum.new
    forum.add_user(1, username: 'chosen', name: 'Chosen')
    forum.add_row(1, 1, SMART.downcase)
    forum.add_row(9, nil, SMART)
    result = transfer(forum, apply: true).run
    assert result[:ok], output
    assert_equal({ 1 => SMART }, forum.rows.map { |id, r| [id, r[:uid]] }.to_h)
    assert_includes output, 'delete siwe row     9 (no user)'
  end

  def test_a_merged_pair_also_replaces_an_orphan_row_on_the_light_account
    forum = FakeForum.new.add_wallet_user(1, EOA_UID, posts: 2)
    forum.add_user(2, username: 'second', name: 'Second', created_at: T0 + 60, posts: 3)
    forum.add_row(2, 2, SMART.downcase)
    forum.add_row(9, nil, SMART)
    result = transfer(forum, **MERGE).run
    assert result[:ok], output
    assert_equal [1], forum.users.keys
    assert_equal({ 1 => SMART }, forum.rows.map { |id, r| [id, r[:uid]] }.to_h)
    assert_equal 2, result[:counts][:rows_deleted]
    assert_includes output, '1 duplicate users merged, 1 orphan rows replaced'
  end
end

# A re-run after a failure backs up a forum that is already partly
# transferred. The output must not present that backup as the way back.
class RollbackPointTest < Minitest::Test
  include TransferHelpers

  MERGE = { apply: true, merge: true, full_backup_taken: true }.freeze

  def test_backup_runs_lists_complete_sets_oldest_first
    names = %w[
      siwe_backup_20261111153000_accounts siwe_backup_20261111153000_fields siwe_backup_20261111153000_users
      siwe_backup_20261111153000_group_users siwe_backup_20261111153000_user_badges
      siwe_backup_20261015160000_accounts siwe_backup_20261015160000_fields siwe_backup_20261015160000_users
      siwe_backup_20260101000000_accounts siwe_backup_20260101000000_fields
      siwe_backup_accounts users
    ]
    assert_equal %w[20261015160000 20261111153000], REWRITE.backup_runs(names)
    assert_empty REWRITE.backup_runs([])
  end

  def test_a_first_apply_mentions_no_earlier_backup
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID)
    assert transfer(forum, apply: true).run[:ok]
    refute_includes output, 'Earlier backups exist'
    assert_includes output, 'use it right after the apply, with wallet sign-ins still off'
  end

  def test_a_re_run_after_a_failed_merge_points_at_the_first_backup
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID).add_smart_user(2, SMART2, created_at: T0 + 60)
    forum.add_wallet_user(3, EOA3_UID)
    forum.fail_on = { merge_users: 1 }
    assert_raises(RuntimeError) { transfer(forum, **MERGE).run }
    assert_includes output, 'if it still exists after the re-run, merge it into user 1 from its admin page'
    assert_equal EOA3_UID, forum.backups[0][:rows][3][:uid]

    result = transfer(forum, **MERGE.merge(run_id: 'r2')).run
    assert result[:ok], output
    assert_equal SMART3, forum.backups[1][:rows][3][:uid] # the second backup is not the original state
    assert_includes output, 'Earlier backups exist: siwe_backup_r1_*.'
    assert_includes output, 'the backup of that first apply (oldest here: r1), not r2'
    assert_includes output, "use the same SQL with that apply's run id (oldest here: r1) in place of r2"
  end
end

# A dry run, an apply and a verify agree only with the same options.
class PlanOptionsTest < Minitest::Test
  include TransferHelpers

  def test_a_dry_run_without_the_login_confirmation_says_suspect_after_changes_the_plan
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID)
    transfer(forum, no_login_deployed: false).run
    assert_includes output, 'NOTE: an apply needs SUSPECT_AFTER or NO_LIGHT_ACCOUNT_LOGIN_DEPLOYED=1'

    transfer(forum).run
    refute_includes output, 'NOTE: an apply needs'
    refute_includes output, 'These options change the plan'
  end

  def test_the_options_that_change_the_plan_are_printed_for_the_next_command
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID).add_wallet_user(2, EOA3_UID)
    forum.rows[2][:created_at] = Time.utc(2026, 10, 16)
    opts = { no_login_deployed: false, suspect_after: Time.utc(2026, 10, 15, 16), reviewed: [2], keep_usernames: true }
    line = 'give the same ones to every dry run, apply and verify: ' \
           'SUSPECT_AFTER=2026-10-15T16:00:00Z REVIEWED_ROWS=2 KEEP_USERNAMES=1'

    transfer(forum, **opts).run
    assert_includes output, line
    assert transfer(forum, **opts.merge(apply: true)).run[:ok]
    assert_includes output, line

    # the same forum without them does not verify: the reason for the line
    refute transfer(forum, no_login_deployed: false).verify[:ok]
    refute_includes output, 'These options change the plan'
    assert transfer(forum, **opts).verify[:ok]
    assert_includes output, line
  end

  def test_suspect_after_without_a_zone_is_utc
    parse = ->(text) { DiscourseSiwe::SmartAccountTransferRunner.parse_time(text) }
    assert_equal Time.utc(2026, 10, 15, 16), parse.call('2026-10-15T16:00:00')
    assert_equal Time.utc(2026, 10, 15, 16), parse.call('2026-10-15 16:00')
    assert_equal Time.utc(2026, 10, 15, 16), parse.call('2026-10-15T16:00:00Z')
    assert_equal Time.utc(2026, 10, 15, 14), parse.call('2026-10-15T16:00:00+02:00')
    assert_equal Time.utc(2026, 10, 15, 18, 30), parse.call('2026-10-15T16:00-0230')
    assert_equal Time.utc(2026, 10, 15), parse.call('2026-10-15')
  end
end

class TransferRunnerEnvTest < Minitest::Test
  include TransferHelpers

  RUNNER = DiscourseSiwe::SmartAccountTransferRunner
  SKIP = { 'SKIP_CODE_CHECK' => '1' }.freeze

  def run_with(forum, env, **opts)
    @lines = []
    RUNNER.run(env: SKIP.merge(env), store: forum, short_name: false, out: ->(line) { @lines << line }, **opts)
  end

  def test_default_is_a_dry_run_against_the_bundled_address_map
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID)
    before = forum.state
    assert run_with(forum, {})
    assert_equal before, forum.state
    assert_includes output, "address map: #{RUNNER::DEFAULT_MAP}"
    assert_includes output, 'DRY RUN: nothing written.'
    assert_includes output, 'SKIP_CODE_CHECK=1'
    assert File.file?(RUNNER::DEFAULT_MAP)
  end

  def test_apply_needs_the_login_confirmation_from_the_environment
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID)
    refute run_with(forum, {}, apply: true)
    assert_equal EOA2_UID, forum.rows[1][:uid]

    assert run_with(forum, { 'NO_LIGHT_ACCOUNT_LOGIN_DEPLOYED' => '1' }, apply: true)
    assert_equal SMART2, forum.rows[1][:uid]
  end

  def test_suspect_after_and_reviewed_rows_are_parsed
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID).add_wallet_user(2, EOA3_UID)
    forum.rows[2][:created_at] = Time.utc(2026, 10, 16)
    env = { 'SUSPECT_AFTER' => '2026-10-15T16:00:00Z' }
    refute run_with(forum, env, apply: true)
    assert_equal [SMART2, EOA3_UID], forum.rows.values.map { |r| r[:uid] }
    assert run_with(forum, env.merge('REVIEWED_ROWS' => ' 2, '), apply: true)
    assert_raises(ArgumentError) { run_with(forum, env.merge('REVIEWED_ROWS' => '2;3'), apply: true) }
  end

  def test_merge_and_full_backup_flags
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID).add_smart_user(2, SMART2, created_at: T0 + 60)
    env = { 'NO_LIGHT_ACCOUNT_LOGIN_DEPLOYED' => '1' }
    refute run_with(forum, env, apply: true)                                   # duplicate left: verification fails
    refute run_with(forum, env.merge('MERGE_DUPLICATES' => '1'), apply: true)  # refused: no full backup
    assert_equal [1, 2], forum.users.keys
    assert run_with(forum, env.merge('MERGE_DUPLICATES' => '1', 'FULL_BACKUP_TAKEN' => '1'), apply: true)
    assert_equal [1], forum.users.keys
  end

  def test_keep_usernames_flag
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID)
    assert run_with(forum, { 'NO_LIGHT_ACCOUNT_LOGIN_DEPLOYED' => '1', 'KEEP_USERNAMES' => '1' }, apply: true)
    assert_equal EOA2_UID[0, 20], forum.users[1][:username]
  end

  def test_verify_only_reads
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID)
    refute run_with(forum, {}, verify_only: true)
    assert_empty forum.calls
  end

  def test_restore_sql_prints_the_sql_of_an_existing_backup_run
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID).add_wallet_user(2, EOA3_UID)
    lines = []
    out = ->(line) { lines << line }
    refute RUNNER.restore_sql('20261111153000', store: forum, out: out)
    assert_includes lines.join("\n"), 'No siwe_backup_* set exists'

    transfer(forum, apply: true, run_id: '20261111153000').run
    forum.rows[2][:uid] = EOA3_UID # a later apply of the same transfer takes a second backup
    transfer(forum, apply: true, run_id: '20261111160000').run
    before = forum.state

    lines.clear
    assert RUNNER.restore_sql(' 20261111153000 ', store: forum, out: out)
    assert_equal REWRITE.restore_sql('20261111153000').lines.map(&:chomp), lines

    lines.clear
    assert RUNNER.restore_sql('20261111160000', store: forum, out: out)
    assert_includes lines.last, 'oldest backup here: 20261111153000'

    lines.clear
    refute RUNNER.restore_sql('20260101000000', store: forum, out: out)
    assert_includes lines.join("\n"), 'Backups here, oldest first: 20261111153000, 20261111160000'
    refute RUNNER.restore_sql("x'; DROP TABLE users; --", store: forum, out: out)
    assert_equal before, forum.state
  end

  def test_no_rpc_and_no_skip_is_an_error_and_the_url_is_never_printed
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID)
    lines = []
    error = assert_raises(RuntimeError) do
      RUNNER.run(env: {}, store: forum, short_name: false, out: ->(line) { lines << line })
    end
    assert_includes error.message, 'No RPC'

    lookup = RUNNER.code_for({ 'RPC_URL' => 'https://rpc.example/v2/secret-key' }, ->(line) { lines << line })
    assert_respond_to lookup, :call
    refute_includes lines.join("\n"), 'secret-key'
  end

  def test_a_custom_address_map_path
    forum = FakeForum.new.add_wallet_user(1, EOA2_UID)
    assert_raises(Errno::ENOENT) { run_with(forum, { 'FORUM_ADDRESS_MAP' => '/nonexistent/map.json' }) }
  end
end
