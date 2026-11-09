# frozen_string_literal: true

module Jobs
  # Per-login sync for one member. Add-only: a login can grant access but
  # never revokes it; the scheduled reconcile owns removals.
  class SyncSiweUserGroups < ::Jobs::Base
    sidekiq_options queue: 'low'

    def execute(args)
      mode = SiteSetting.siwe_group_sync_mode
      return unless %w[log enforce].include?(mode)
      return unless args[:user_id]

      DistributedMutex.synchronize("siwe_group_sync_user_#{args[:user_id]}", validity: 5.minutes) do
        DiscourseSiwe::GroupSyncRunner.run(mode: mode, user_ids: [args[:user_id]], add_only: true, persist_state: false)
      end
    end
  end
end
