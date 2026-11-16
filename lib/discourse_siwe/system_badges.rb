# frozen_string_literal: true

module DiscourseSiwe
  # Retires Discourse's built-in (system) badges in favour of the mirrored
  # Society badges.
  #
  #   disable!       enabled = false on every system badge, per record with
  #                  update! so Badge's after_commit callbacks run (grant
  #                  counts, distinct badge counts, featured ranks). Nothing is
  #                  deleted. Idempotent. SiteSetting.enable_badges is left on:
  #                  turning it off makes every grant return early and /badges 404.
  #   purge_grants!  opt-in and destructive: deletes the UserBadge rows and
  #                  granted_badge notifications of system badges. Needs the
  #                  system badges to be disabled first.
  #
  # Mirrored badges are never touched (system badges have ids below 100 and
  # system = true; mirrored ones are created with system = false and id >= 100,
  # and are additionally excluded by id).
  module SystemBadges
    module_function

    def system_badge_ids
      Badge.where(system: true).pluck(:id) - mirrored_badge_ids
    end

    def mirrored_badge_ids
      BadgeMirrorRunner::RecordStore.new.records.values.map { |r| r[:badge_id] }.compact.map(&:to_i)
    end

    # What exists, so a human can decide on deletion.
    def inventory
      ids = system_badge_ids
      {
        badges: ids.size,
        enabled: Badge.where(id: ids, enabled: true).count,
        user_badges: UserBadge.where(badge_id: ids).count,
        notifications: notifications(ids).count,
        titles: UserProfile.where(granted_title_badge_id: ids).count,
        enable_badges: SiteSetting.enable_badges,
      }
    end

    # => { disabled: [names], already_disabled: n, inventory: {...} }
    def disable!(dry_run:)
      targets = Badge.where(id: system_badge_ids, enabled: true).order(:id).to_a
      result = { disabled: targets.map(&:name), already_disabled: Badge.where(id: system_badge_ids, enabled: false).count, dry_run: dry_run }
      unless dry_run
        targets.each { |badge| badge.update!(enabled: false) }
        audit("disabled #{targets.size} Discourse system badges") if targets.any?
      end
      result.merge(inventory: inventory)
    end

    # => { user_badges: n, notifications: n, dry_run: bool }
    # Raises when a system badge is still enabled.
    def purge_grants!(dry_run:)
      ids = system_badge_ids
      before = { user_badges: UserBadge.where(badge_id: ids).count, notifications: notifications(ids).count }
      still_enabled = Badge.where(id: ids, enabled: true).count
      raise "#{still_enabled} system badges are still enabled; run siwe:badges:disable_system first" if still_enabled.positive? && !dry_run
      return before.merge(dry_run: true) if dry_run

      # destroy! so counters, featured ranks and events stay consistent; the
      # linked notification goes with each user badge.
      UserBadge.where(badge_id: ids).find_each(&:destroy!)
      notifications(ids).delete_all
      BadgeGranter.revoke_ungranted_titles!
      audit("purged #{before[:user_badges]} system user badges and #{before[:notifications]} notifications")
      before.merge(dry_run: false)
    end

    # notifications.data is a varchar(1000) holding JSON, so it is cast. The
    # CASE keeps the cast away from rows that are not granted_badge.
    def notifications(badge_ids)
      type = Notification.types[:granted_badge]
      Notification.where(notification_type: type).where(
        "CASE WHEN notifications.notification_type = ? THEN (notifications.data::jsonb ->> 'badge_id')::int END IN (?)",
        type, badge_ids.empty? ? [-1] : badge_ids
      )
    end

    def audit(details)
      StaffActionLogger.new(Discourse.system_user).log_custom('siwe_badge_sync', subject: 'system badges', details: details)
    end
  end
end
