#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit tests for what the smart-account transfer does with the group sync
# and badge mirror state (staging line only): the absence counters in the
# plugin store and the per-login badge debounce. The Discourse classes it
# touches are replaced by small in-memory stand-ins.
#
# Run: ruby -r./test/support/pure_keccak -rtime test/smart_account_sync_state_unit_test.rb

require_relative 'support/pure_keccak'
require 'json'
require 'time'
require 'set'
require 'minitest/autorun'
require_relative '../lib/discourse_siwe/eth_rpc'
require_relative '../lib/discourse_siwe/light_account'
require_relative '../lib/discourse_siwe/group_sync_planner'
require_relative '../lib/discourse_siwe/smart_account_transfer_runner'

SYNC_STATE = DiscourseSiwe::SmartAccountSyncState

# ---- stand-ins for the Discourse classes SmartAccountSyncState.apply uses ----

module PluginStore
  ROWS = {}

  def self.get(plugin, key)
    value = ROWS[[plugin, key]]
    value && JSON.parse(value) # as Discourse: string keys after a round trip
  end

  def self.set(plugin, key, value)
    ROWS[[plugin, key]] = JSON.generate(value)
  end
end

module DistributedMutex
  LOCKS = []

  def self.synchronize(name, validity:)
    LOCKS << [name, validity]
    yield
  end
end

class UserCustomField
  ROWS = []
  Scope = Struct.new(:rows) do
    def delete_all
      rows.each { |row| ROWS.delete(row) }.size
    end
  end

  def self.where(user_id:, name:)
    Scope.new(ROWS.select { |row| Array(user_id).include?(row[:user_id]) && row[:name] == name })
  end
end

module ActiveRecord
  class Base
    SQL = []

    def self.connection
      self
    end

    def self.execute(sql)
      SQL << sql
    end
  end
end

class SyncStatePruneTest < Minitest::Test
  def test_drops_only_the_given_users_in_every_group
    pending = { 'vip' => { 7 => 1, 9 => 2 }, 'governors' => { 7 => 1 }, 'empty' => {} }
    pruned, dropped = SYNC_STATE.prune(pending, [7])
    assert_equal({ 'vip' => { 9 => 2 }, 'governors' => {}, 'empty' => {} }, pruned)
    assert_equal 2, dropped
    assert_equal({ 7 => 1, 9 => 2 }, pending['vip']) # the input is not changed
  end

  def test_ids_read_back_from_json_are_strings
    pruned, dropped = SYNC_STATE.prune({ '13' => { '7' => 1, '70' => 1, '17' => 3 } }, [7])
    assert_equal({ '13' => { '70' => 1, '17' => 3 } }, pruned)
    assert_equal 1, dropped
  end

  def test_nothing_to_drop_and_odd_shapes
    assert_equal [{}, 0], SYNC_STATE.prune(nil, [1])
    assert_equal [{ 'vip' => { 2 => 1 } }, 0], SYNC_STATE.prune({ 'vip' => { 2 => 1 } }, [])
    assert_equal [{ 'vip' => 'broken' }, 0], SYNC_STATE.prune({ 'vip' => 'broken' }, [1])
  end

  # Why the counters are dropped: a count gathered on the old address set
  # would remove the member after a single look at the new one.
  def test_a_transferred_member_gets_the_full_confirmation_window_again
    planner = DiscourseSiwe::GroupSyncPlanner
    args = { desired: Set.new, current: Set[7], protected: Set.new, unknown: Set.new, confirmations: 2 }
    assert_equal [7], planner.plan(**args.merge(pending: { 7 => 1 })).remove

    pruned, = SYNC_STATE.prune({ 'vip' => { 7 => 1 } }, [7])
    plan = planner.plan(**args.merge(pending: pruned['vip']))
    assert_empty plan.remove
    assert_equal({ 7 => 1 }, plan.next_pending)
  end
end

class SyncStateBackupTest < Minitest::Test
  def test_backs_up_the_two_counter_rows
    tables = SYNC_STATE.backup_tables('r1')
    assert_equal ['siwe_backup_r1_plugin_store'], tables.map(&:first)
    assert_includes tables[0][1], "plugin_name = 'discourse-siwe-auth'"
    assert_includes tables[0][1], "key IN ('group_sync_pending', 'badge_mirror_pending')"
    assert_raises(ArgumentError) { SYNC_STATE.backup_tables('r1; DROP') }
  end

  def test_the_store_backup_adds_it_to_the_transfer_tables
    ActiveRecord::Base::SQL.clear
    tables = DiscourseSiwe::SmartAccountTransferRunner::Store.new.backup('r2', merge_user_ids: [])
    assert_equal %w[siwe_backup_r2_accounts siwe_backup_r2_fields siwe_backup_r2_users siwe_backup_r2_plugin_store], tables
    assert_equal 4, ActiveRecord::Base::SQL.size
    assert(ActiveRecord::Base::SQL.all? { |sql| sql.start_with?('CREATE TABLE siwe_backup_r2_') && sql.include?(' AS SELECT ') })
  end
end

class SyncStateApplyTest < Minitest::Test
  STORE = 'discourse-siwe-auth'

  def setup
    PluginStore::ROWS.clear
    DistributedMutex::LOCKS.clear
    UserCustomField::ROWS.clear
    PluginStore.set(STORE, 'group_sync_pending', { 'vip' => { 1 => 1, 2 => 1, 5 => 1 } })
    PluginStore.set(STORE, 'badge_mirror_pending', { '13' => { 2 => 1 }, '14' => { 5 => 2 } })
    PluginStore.set(STORE, 'badge_mirror_hold', true)
    [1, 2, 5].each { |id| UserCustomField::ROWS << { user_id: id, name: 'siwe_badges_synced_at', value: '1' } }
    UserCustomField::ROWS << { user_id: 1, name: 'wallet_address', value: '0x' }
  end

  def test_drops_the_counters_of_moved_and_merged_users_under_the_job_locks
    lines = SYNC_STATE.apply(moved_user_ids: [1], merged: { 2 => 1 })

    assert_equal({ 'vip' => { '5' => 1 } }, PluginStore.get(STORE, 'group_sync_pending'))
    assert_equal({ '13' => {}, '14' => { '5' => 2 } }, PluginStore.get(STORE, 'badge_mirror_pending'))
    assert_equal true, PluginStore.get(STORE, 'badge_mirror_hold')
    assert_equal [['siwe_group_sync', 300], ['siwe_badge_mirror', 300]], DistributedMutex::LOCKS
    assert_equal [{ user_id: 5, name: 'siwe_badges_synced_at', value: '1' }, { user_id: 1, name: 'wallet_address', value: '0x' }],
                 UserCustomField::ROWS
    assert_equal [
      'group_sync_pending: dropped 2 absence counter(s) of transferred users',
      'badge_mirror_pending: dropped 1 absence counter(s) of transferred users',
      'siwe_badges_synced_at: cleared for 2 user(s), their next sign-in mirrors badges at once',
    ], lines
  end

  def test_nothing_moved_touches_nothing
    before = PluginStore::ROWS.dup
    assert_empty SYNC_STATE.apply(moved_user_ids: [], merged: {})
    assert_equal before, PluginStore::ROWS
    assert_empty DistributedMutex::LOCKS
    assert_equal 4, UserCustomField::ROWS.size
  end

  def test_users_without_counters_leave_the_rows_unwritten
    before = PluginStore::ROWS.dup
    assert_empty SYNC_STATE.apply(moved_user_ids: [99], merged: {})
    assert_equal before, PluginStore::ROWS
  end

  def test_missing_rows_are_fine
    PluginStore::ROWS.clear
    assert_empty SYNC_STATE.apply(moved_user_ids: [99], merged: {})
  end

  def test_the_transfer_store_hook_delegates_here
    lines = DiscourseSiwe::SmartAccountTransferRunner::Store.new.after_transfer(moved_user_ids: [5], merged: {})
    assert_equal({ '13' => { '2' => 1 }, '14' => {} }, PluginStore.get(STORE, 'badge_mirror_pending'))
    assert_equal 3, lines.size
  end
end
