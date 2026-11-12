# frozen_string_literal: true

module Jobs
  # Hourly full reconcile of the mirrored Society badges: catalog, then every
  # member. The only place revokes are decided. Also re-applies the system
  # badge disable when siwe_badges_disable_system is on, because a Discourse
  # upgrade can add new system badges (already-disabled ones stay disabled).
  class SiweBadgeMirror < ::Jobs::Scheduled
    every 1.hour

    def execute(_args)
      return unless SiteSetting.discourse_siwe_enabled

      mode = SiteSetting.siwe_badges_sync_mode
      DiscourseSiwe::BadgeMirrorRunner.run_full(mode: mode) if %w[log enforce].include?(mode)

      return unless SiteSetting.siwe_badges_disable_system
      return if mode == 'log' # log mode changes nothing

      DiscourseSiwe::SystemBadges.disable!(dry_run: false)
    end
  end
end
