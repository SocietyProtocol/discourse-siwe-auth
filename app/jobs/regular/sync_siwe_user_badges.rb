# frozen_string_literal: true

module Jobs
  # Per-login badge sync for one member: grants what they hold and revokes
  # what they no longer hold (with the same confirmation counters, and never
  # while a failed or braked full run has revokes on hold). Debounced to
  # about an hour per member. The catalog is left to the scheduled job.
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
