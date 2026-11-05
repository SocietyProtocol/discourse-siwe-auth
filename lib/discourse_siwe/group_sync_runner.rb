# frozen_string_literal: true

module DiscourseSiwe
  # Wires BadgeGroupSync to real Discourse: users, groups, plugin store and
  # the badges contract. Everything with a rule lives in BadgeGroupSync and
  # GroupSyncPlanner; this file only adapts.
  module GroupSyncRunner
    STORE = 'discourse-siwe-auth'
    PENDING_KEY = 'group_sync_pending'
    REPORT_KEY = 'group_sync_last_report'

    module_function

    def mapping
      parsed = BadgeGroupMapping.parse(
        SiteSetting.siwe_group_badge_mapping,
        reserved: Group::AUTO_GROUPS.keys.map(&:to_s) + Group.where(automatic: true).pluck(:name),
      )
      parsed.errors.each { |e| log("mapping: #{e}") }
      parsed.groups
    end

    # mode: 'log' | 'enforce'. user_ids: limit to these users (login job).
    def run(mode:, user_ids: nil, add_only: false, persist_state: true)
      sync = BadgeGroupSync.new(
        mapping: mapping,
        users: eligible_users(user_ids),
        ownership: ownership,
        groups: GroupStore.new(mode == 'enforce'),
        state: State.new,
        log: method(:log),
        confirmations: SiteSetting.siwe_group_sync_removal_confirmations,
        floor: SiteSetting.siwe_group_sync_removal_floor,
        percent: SiteSetting.siwe_group_sync_removal_percent,
      )
      result = sync.run(mode: mode, add_only: add_only, persist_state: persist_state)
      store_report(result, user_ids)
      log("run finished: #{result[:status]}#{" (#{result[:error]})" if result[:error]}")
      result
    end

    def last_report
      PluginStore.get(STORE, REPORT_KEY)
    end

    def ownership
      lambda do |addresses, badge_ids|
        BadgeOwnership.balances(
          addresses, badge_ids,
          contract: SiteSetting.siwe_society_badges_contract.to_s,
          url: EthRpc.badges_rpc_url,
          expected_chain_id: SiteSetting.siwe_society_badges_chain_id,
        )
      end
    end

    # Active, real members. Staged, inactive, system and anonymous accounts
    # are never touched. Staff and the exempt list are `protected`: they are
    # added when they hold a badge but never removed.
    def eligible_users(user_ids)
      scope = User.real.where(active: true, staged: false)
      scope = scope.where(id: user_ids) if user_ids

      ids = scope.pluck(:id)
      fields = Hash.new { |h, k| h[k] = {} }
      UserCustomField.where(user_id: ids, name: %w[wallet_address siwe_owner_address]).each do |f|
        fields[f.user_id][f.name] = f.value
      end

      exempt = SiteSetting.siwe_group_sync_exempt_usernames.to_s.split('|').map { |n| n.strip.downcase }.reject(&:empty?)
      address_map = MemberAddresses.load_address_map(
        File.expand_path('../../script/forum-address-map.json', __dir__),
        chain_id: SiteSetting.siwe_society_badges_chain_id.to_i.positive? ? SiteSetting.siwe_society_badges_chain_id : nil,
      )

      scope.select(:id, :username, :admin, :moderator).map do |user|
        {
          id: user.id,
          username: user.username,
          addresses: MemberAddresses.addresses_for(fields[user.id], address_map: address_map),
          protected: user.admin || user.moderator || exempt.include?(user.username.downcase),
        }
      end
    end

    def store_report(result, user_ids)
      return if user_ids # per-login runs do not overwrite the full report

      PluginStore.set(STORE, REPORT_KEY, result.merge(at: Time.now.utc.iso8601))
    end

    def log(message)
      Rails.logger.info("[discourse-siwe-auth] group sync: #{message}")
    end

    # Group access for BadgeGroupSync. Reads are always real; writes happen
    # only when `writable` (enforce mode) and are logged for staff.
    class GroupStore
      def initialize(writable)
        @writable = writable
        @cache = {}
      end

      def group(name)
        return @cache[name] if @cache.key?(name)

        @cache[name] = Group.where('lower(name) = ?', name.downcase).first
      end

      def members(name)
        g = group(name)
        g && Set.new(g.group_users.pluck(:user_id))
      end

      def protected_members(name)
        g = group(name)
        g ? Set.new(g.group_users.where(owner: true).pluck(:user_id)) : Set.new
      end

      def add(name, user_id)
        return unless @writable

        user = User.find_by(id: user_id)
        return unless user

        group(name).add(user)
        audit('added', user, name)
      rescue ActiveRecord::RecordNotUnique
        nil # a login job added them first
      end

      def remove(name, user_id)
        return unless @writable

        user = User.find_by(id: user_id)
        return unless user

        group(name).remove(user)
        audit('removed', user, name)
      end

      private

      def audit(action, user, group_name)
        StaffActionLogger.new(Discourse.system_user).log_custom(
          'siwe_group_sync',
          subject: user.username,
          details: "#{action} #{user.username} #{action == 'added' ? 'to' : 'from'} #{group_name} (on-chain badge holdings)",
        )
      end
    end

    # Absence counters between runs, kept in the plugin store.
    class State
      def pending
        raw = PluginStore.get(STORE, PENDING_KEY) || {}
        raw.each_with_object({}) do |(group, counts), out|
          out[group.to_s] = counts.each_with_object({}) { |(id, n), h| h[id.to_i] = n.to_i }
        end
      end

      def save_pending(value)
        PluginStore.set(STORE, PENDING_KEY, value)
      end
    end
  end
end
