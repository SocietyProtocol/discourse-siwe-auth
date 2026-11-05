# frozen_string_literal: true

module Jobs
  # Full reconcile of badge-driven groups. The only place removals happen.
  class SiweGroupSync < ::Jobs::Scheduled
    every 30.minutes

    def execute(_args)
      mode = SiteSetting.siwe_group_sync_mode
      return unless %w[log enforce].include?(mode)

      DistributedMutex.synchronize('siwe_group_sync', validity: 30.minutes) do
        DiscourseSiwe::GroupSyncRunner.run(mode: mode)
      end
    end
  end
end
