# frozen_string_literal: true

require_relative 'smart_account_rewrite'

module DiscourseSiwe
  # What the badge-driven group sync and the badge mirror remember per forum
  # user, and what a smart-account transfer does with it.
  #
  # Both keep "seen without the badge N runs in a row" counters in the plugin
  # store, keyed by user id:
  #
  #   group_sync_pending    { group => { user_id => runs } }
  #   badge_mirror_pending  { token => { user_id => runs } }
  #
  # A member leaves a group or loses a mirrored badge when the count reaches
  # the confirmations setting. The transfer changes the addresses a member is
  # judged by (the wallet becomes S, the owner E is added) and can merge two
  # users. Counters gathered before that are dropped for those users, so a
  # transferred member gets the full number of confirmations on the new
  # address set and a merged-away user id does not linger. Dropping a counter
  # can only delay a removal; it never causes one.
  #
  # The per-login badge debounce (siwe_badges_synced_at) is cleared as well,
  # so the member's next sign-in mirrors their badges at once.
  #
  # Nothing else the two features store names a member: group memberships
  # and UserBadge rows are keyed by user id and follow a merge through
  # UserMerger; badge_mirror:token:* records, meta, hold and the last reports
  # hold no address.
  module SmartAccountSyncState
    STORE = 'discourse-siwe-auth'
    SYNCED_FIELD = 'siwe_badges_synced_at'

    # plugin store key => the mutex its scheduled job holds while it runs
    # (Jobs::SiweGroupSync, BadgeMirrorRunner.run_full).
    PENDING_LOCKS = {
      'group_sync_pending' => 'siwe_group_sync',
      'badge_mirror_pending' => 'siwe_badge_mirror',
    }.freeze

    module_function

    # pending: { name => { user_id => runs } }; ids are Integers or, read
    # back from JSON, Strings. => [copy without those users, counters dropped]
    def prune(pending, user_ids)
      drop = user_ids.map(&:to_i)
      dropped = 0
      pruned = {}
      (pending || {}).each do |name, counts|
        unless counts.is_a?(Hash)
          pruned[name] = counts
          next
        end

        kept = counts.reject { |id, _runs| drop.include?(id.to_i) }
        dropped += counts.size - kept.size
        pruned[name] = kept
      end
      [pruned, dropped]
    end

    # [[table, select]] added to the transfer's backup. A record only:
    # the counters rebuild themselves, nothing restores from it.
    def backup_tables(run)
      raise ArgumentError, "invalid backup run id: #{run.inspect}" unless run.to_s.match?(SmartAccountRewrite::RUN_ID_RE)

      keys = PENDING_LOCKS.keys.map { |key| "'#{key}'" }.join(', ')
      [["siwe_backup_#{run}_plugin_store",
        "SELECT * FROM plugin_store_rows WHERE plugin_name = '#{STORE}' AND key IN (#{keys})"]]
    end

    # moved_user_ids: users whose account changed address in this run.
    # merged: { merged-away user id => surviving user id }.
    # Returns the lines to print. Needs Discourse.
    def apply(moved_user_ids:, merged:)
      ids = (moved_user_ids + merged.keys + merged.values).map(&:to_i).uniq
      return [] if ids.empty?

      lines = []
      PENDING_LOCKS.each do |key, lock|
        DistributedMutex.synchronize(lock, validity: 300) do
          raw = PluginStore.get(STORE, key)
          next unless raw.is_a?(Hash)

          pruned, dropped = prune(raw, ids)
          next if dropped.zero?

          PluginStore.set(STORE, key, pruned)
          lines << "#{key}: dropped #{dropped} absence counter(s) of transferred users"
        end
      end

      cleared = UserCustomField.where(user_id: ids, name: SYNCED_FIELD).delete_all
      lines << "#{SYNCED_FIELD}: cleared for #{cleared} user(s), their next sign-in mirrors badges at once" if cleared.positive?
      lines
    end
  end
end
