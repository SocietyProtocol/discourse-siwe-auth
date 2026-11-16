# frozen_string_literal: true

module Jobs
  # Per-login badge sync for one member: grants what they hold. ADD-ONLY: it
  # never revokes and never reads or writes the confirmation counters or the
  # revoke hold, so it cannot race the hourly full run or get around its
  # brakes. Revokes (and the catalog) belong to the scheduled job, which runs
  # under a DistributedMutex. Debounced to about an hour per member.
  class SyncSiweUserBadges < ::Jobs::Base
    sidekiq_options queue: 'low'

    def execute(args)
      return unless SiteSetting.discourse_siwe_enabled
      # Log mode would only recompute a report nobody reads per login.
      return unless SiteSetting.siwe_badges_sync_mode == 'enforce'

      user_id = args[:user_id]
      return unless user_id

      DistributedMutex.synchronize("siwe_badge_mirror_user_#{user_id}", validity: 5.minutes) do
        next unless DiscourseSiwe::BadgeMirrorRunner.login_due?(user_id)

        result = DiscourseSiwe::BadgeMirrorRunner.run(mode: 'enforce', user_ids: [user_id])
        DiscourseSiwe::BadgeMirrorRunner.mark_synced(user_id) unless %i[source_error error].include?(result[:status])
      end
    end
  end
end
