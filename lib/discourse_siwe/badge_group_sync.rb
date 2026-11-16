# frozen_string_literal: true

require 'set'
require_relative 'badge_group_mapping'
require_relative 'badge_ownership'
require_relative 'group_sync_planner'

module DiscourseSiwe
  # Makes forum groups follow on-chain badge holders.
  #
  # This class holds no Discourse or network code. Its collaborators are
  # passed in so the safety rules are testable:
  #
  #   mapping    { "group-name" => [badge_id, ...] }
  #   users      [{ id:, username:, addresses: [..], protected: bool }]
  #   ownership  ->(addresses, badge_ids) { { address => { id => Integer|nil } } }
  #              raising BadgeOwnership::SourceError when the chain is unusable
  #   groups     #members(name) -> Set|nil (nil: group does not exist)
  #              #protected_members(name) -> Set (owners)
  #              #add(name, user_id) / #remove(name, user_id)
  #   state      #pending -> { group => { user_id => runs } }; #save_pending(h)
  #   log        ->(message)
  #
  # A source failure aborts the run before anything is changed.
  class BadgeGroupSync
    MODES = %w[log enforce].freeze

    def initialize(mapping:, users:, ownership:, groups:, state:, log: ->(_m) {}, confirmations: 2, floor: 3, percent: 20)
      @mapping = mapping
      @users = users
      @ownership = ownership
      @groups = groups
      @state = state
      @log = log
      @confirmations = confirmations
      @floor = floor
      @percent = percent
    end

    # mode: 'log' reports what would change, 'enforce' applies it.
    # add_only: never remove (used by the per-login job).
    # persist_state: record the absence counters (rake dry runs do not).
    def run(mode:, add_only: false, persist_state: true)
      raise ArgumentError, "mode must be one of #{MODES.join(', ')}" unless MODES.include?(mode)
      return report(:no_mapping, mode) if @mapping.empty?

      with_wallets = @users.select { |u| u[:addresses].any? }
      return report(:no_members, mode) if with_wallets.empty?

      badge_ids = BadgeGroupMapping.badge_ids(@mapping)
      addresses = with_wallets.flat_map { |u| u[:addresses] }.uniq
      balances = fetch(addresses, badge_ids)
      return report(:source_error, mode, error: @error) unless balances

      holdings = classify(with_wallets, balances)
      pending = @state.pending
      next_pending = {}
      groups_report = {}

      @mapping.each do |group, ids|
        members = @groups.members(group)
        if members.nil?
          groups_report[group] = { missing: true }
          @log.call("group #{group} does not exist; run siwe:groups:bootstrap")
          next
        end

        desired = Set.new
        unknown = Set.new
        holdings.each do |user_id, held|
          if (held[:held] & ids).any?
            desired << user_id
          elsif (held[:unknown] & ids).any?
            unknown << user_id
          end
        end
        # Members with no wallet on record cannot be evaluated: leave them.
        wallet_ids = Set.new(with_wallets.map { |u| u[:id] })
        unknown.merge(members - wallet_ids)

        protected_ids = Set.new(@users.select { |u| u[:protected] }.map { |u| u[:id] })
        protected_ids.merge(@groups.protected_members(group))

        plan = GroupSyncPlanner.plan(
          desired: desired, current: members, protected: protected_ids, unknown: unknown,
          pending: (pending[group] || {}), confirmations: @confirmations, floor: @floor, percent: @percent,
        )
        plan.remove.clear if add_only
        next_pending[group] = plan.next_pending

        apply(group, plan) if mode == 'enforce'
        groups_report[group] = describe(group, plan, mode)
      end

      @state.save_pending(next_pending) if persist_state && !add_only && mode == 'enforce'
      report(:ok, mode, groups: groups_report)
    end

    private

    def fetch(addresses, badge_ids)
      balances = @ownership.call(addresses, badge_ids)
      # If nothing at all could be read the source is down, whatever the
      # individual calls said.
      known = balances.values.flat_map(&:values).compact
      if known.empty?
        @error = 'no balance could be read'
        return nil
      end
      balances
    rescue BadgeOwnership::SourceError => e
      @error = e.message
      nil
    end

    # => { user_id => { held: Set[badge ids], unknown: Set[badge ids] } }
    def classify(users, balances)
      users.each_with_object({}) do |user, out|
        held = Set.new
        unknown = Set.new
        balances_for(user, balances).each do |id, values|
          if values.compact.any?(&:positive?)
            held << id
          elsif values.include?(nil)
            unknown << id
          end
        end
        out[user[:id]] = { held: held, unknown: unknown }
      end
    end

    # { badge_id => [balance on each of the user's addresses] }
    def balances_for(user, balances)
      result = Hash.new { |h, k| h[k] = [] }
      user[:addresses].each do |address|
        row = balances[address] || {}
        BadgeGroupMapping.badge_ids(@mapping).each { |id| result[id] << row[id] }
      end
      result
    end

    def apply(group, plan)
      plan.add.each { |user_id| @groups.add(group, user_id) }
      plan.remove.each { |user_id| @groups.remove(group, user_id) }
    end

    def describe(group, plan, mode)
      names = @users.each_with_object({}) { |u, h| h[u[:id]] = u[:username] }
      label = ->(ids) { ids.map { |id| names[id] || "##{id}" } }
      summary = {
        add: label.call(plan.add), remove: label.call(plan.remove),
        deferred: label.call(plan.deferred), kept: label.call(plan.kept), braked: plan.braked,
      }
      verb = mode == 'enforce' ? 'applied' : 'would'
      @log.call(
        "#{group}: #{verb} add=#{summary[:add].size} remove=#{summary[:remove].size} " \
        "deferred=#{summary[:deferred].size} kept=#{summary[:kept].size}#{' BRAKED' if plan.braked}",
      )
      summary
    end

    def report(status, mode, extra = {})
      { status: status, mode: mode }.merge(extra)
    end
  end
end
