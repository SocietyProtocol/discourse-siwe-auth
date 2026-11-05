# frozen_string_literal: true

require 'digest'

module DiscourseSiwe
  # Wires BadgeMirror to real Discourse: Badge/UserBadge rows, BadgeGranter,
  # uploads, the plugin store and the badges contract. Every rule lives in
  # BadgeMirror, BadgeCatalog and BadgeContent; this file only adapts.
  #
  # Discourse APIs used (checked against 2026.8.0):
  #   BadgeGranter.grant(badge, user, granted_by:, suppress_notification:)
  #   BadgeGranter.revoke(user_badge, revoked_by: optional)
  #   FileHelper.download(url, max_file_size:, tmp_file_name:, ...)  (SSRF guarded)
  #   UploadCreator.new(file, filename, type: 'badge_image').create_for(user_id)
  module BadgeMirrorRunner
    STORE = 'discourse-siwe-auth'
    RECORD_PREFIX = 'badge_mirror:token:'
    META_KEY = 'badge_mirror_meta'
    PENDING_KEY = 'badge_mirror_pending'
    HOLD_KEY = 'badge_mirror_hold'
    REPORT_KEY = 'badge_mirror_last_report'
    SYNCED_FIELD = 'siwe_badges_synced_at'
    MUTEX = 'siwe_badge_mirror'
    LOGIN_DEBOUNCE_SECONDS = 3600
    FORCE_FLOOR = 1_000_000_000

    module_function

    def config(force: false)
      allowlist = SiteSetting.siwe_badges_community_allowlist.to_s.split('|').map { |v| BadgeContent.token_id(v) }.compact
      BadgeMirror.config(
        allowlist: Set.new(allowlist),
        confirmations: force ? 1 : SiteSetting.siwe_badges_revoke_confirmations,
        floor: force ? FORCE_FLOOR : SiteSetting.siwe_badges_revoke_floor,
        percent: force ? 100 : SiteSetting.siwe_badges_revoke_percent,
        notify: SiteSetting.siwe_badges_notify_on_grant,
        app_url: SiteSetting.siwe_badges_app_url.to_s,
      )
    end

    # Full reconcile (catalog + every member), serialised across processes.
    # force: skip the confirmation counters and the brakes (rake only).
    def run_full(mode:, force: false, persist_report: true)
      DistributedMutex.synchronize(MUTEX, validity: 30.minutes) do
        run(mode: mode, force: force, persist_report: persist_report)
      end
    end

    # mode: 'log' | 'enforce'. user_ids: only these members (login job).
    def run(mode:, user_ids: nil, revoke: true, force: false, persist_report: true)
      unless SiteSetting.enable_badges
        result = { status: :error, mode: mode, error: 'enable_badges is off; Discourse refuses grants' }
        store_report(result, user_ids) if persist_report
        return result
      end

      mirror = BadgeMirror.new(
        catalog: user_ids ? nil : catalog_source,
        store: RecordStore.new, badges: BadgeStore.new, images: method(:fetch_image),
        grants: GrantStore.new(mode == 'enforce'), users: eligible_users,
        ownership: GroupSyncRunner.ownership, config: config(force: force), log: method(:log),
      )
      result = mirror.run(mode: mode, user_ids: user_ids, revoke: revoke)
      store_report(result, user_ids) if persist_report
      log("run finished: #{result[:status]}#{" (#{result[:error]})" if result[:error]}")
      result
    end

    def last_report
      PluginStore.get(STORE, REPORT_KEY)
    end

    def store_report(result, user_ids)
      return if user_ids # per-login runs do not overwrite the full report

      PluginStore.set(STORE, REPORT_KEY, result.merge(at: Time.now.utc.iso8601))
    end

    def catalog_source
      client = SubgraphClient.new(
        url: SiteSetting.siwe_society_subgraph_url, token: SiteSetting.siwe_society_subgraph_token,
      )
      -> { BadgeCatalog.fetch(client) }
    end

    # Members the sync may act on: the F2 member list (active, not staged,
    # not anonymous, wallet on record) minus suspended and silenced users.
    def eligible_users
      users = GroupSyncRunner.eligible_users(nil).select { |u| u[:addresses].any? }
      ok = Set.new(User.where(id: users.map { |u| u[:id] }).not_suspended.not_silenced.pluck(:id))
      users.select { |u| ok.include?(u[:id]) }
    end

    # ---- per-login debounce ------------------------------------------------

    def login_due?(user_id)
      value = UserCustomField.where(user_id: user_id, name: SYNCED_FIELD).pluck(:value).first
      BadgeMirror.login_due?(value && value.to_i, Time.now.utc, interval: LOGIN_DEBOUNCE_SECONDS)
    end

    def mark_synced(user_id)
      field = UserCustomField.find_or_initialize_by(user_id: user_id, name: SYNCED_FIELD)
      field.value = Time.now.utc.to_i.to_s
      field.save!
    end

    # ---- image -------------------------------------------------------------

    # Downloads (SSRF guarded by FinalDestination: private/loopback ranges and
    # DNS rebinding are refused, redirects are re-checked), keeps only real
    # image types under the size cap, and stores it as a badge_image upload.
    # => { upload_id:, hash: } or nil. Never raises.
    def fetch_image(url)
      tmp = FileHelper.download(
        url, max_file_size: BadgeContent::IMAGE_MAX_BYTES, tmp_file_name: 'siwe-badge',
             follow_redirect: true, read_timeout: 10
      )
      return nil unless tmp

      type = FastImage.type(tmp.path)
      unless BadgeContent.image_type_allowed?(type)
        log('image rejected: not a png, jpeg, gif, webp or svg')
        return nil
      end

      digest = Digest::SHA1.file(tmp.path).hexdigest
      extension = type == :jpeg ? 'jpg' : type.to_s
      upload = UploadCreator.new(tmp, "society-badge-#{digest[0, 8]}.#{extension}", type: 'badge_image')
                            .create_for(Discourse.system_user.id)
      unless upload && upload.persisted? && upload.errors.empty?
        log("image rejected by upload validation: #{upload&.errors&.full_messages&.first}")
        return nil
      end

      { upload_id: upload.id, hash: digest }
    rescue StandardError => e
      log("image fetch failed (#{e.class})")
      nil
    ensure
      begin
        tmp.close! if tmp.respond_to?(:close!)
      rescue StandardError
        nil
      end
    end

    # ---- report ------------------------------------------------------------

    def format_report(result)
      lines = ["status: #{result[:status]} (mode #{result[:mode]})#{result[:at] ? " at #{result[:at]}" : ''}"]
      lines << "error: #{result[:error]}" if result[:error]
      lines << "revokes blocked: #{result[:revoke_blocked]}" if result[:revoke_blocked]
      lines << 'BRAKED across the whole run: too many revokes at once, none applied' if result[:braked_global]
      if (c = result[:catalog])
        if c[:error]
          lines << "catalog: unavailable (#{c[:error]})"
        else
          lines << "catalog: #{c[:seen]} badges on chain, #{c[:rejected]} rows rejected"
          lines << "  NOT TRUSTED, no catalog changes: #{c[:distrust]}" if c[:distrust]
          %i[created updated archived unarchived].each do |key|
            lines << "  #{key}: #{c[key].join(', ')}" if c[key].any?
          end
          i = c[:images]
          lines << "  images: #{i[:fetched]} fetched, #{i[:failed]} failed, #{i[:deferred]} deferred" if i.values.any?(&:positive?)
        end
      end
      (result[:duplicates_skipped] || []).each { |d| lines << "duplicate account #{d[:skipped]} skipped (kept #{d[:kept]})" }
      (result[:badges] || {}).each do |token, b|
        lines << "  badge #{token} (#{b[:name]}):"
        lines << "    add:      #{b[:add].join(', ')}" if b[:add].any?
        lines << "    remove:   #{b[:remove].join(', ')}" if b[:remove].any?
        lines << "    deferred: #{b[:deferred].join(', ')} (absent, awaiting confirmation)" if b[:deferred].any?
        lines << '    BRAKED: too many revokes at once, none applied' if b[:braked]
        lines << '    no changes' if b.values_at(:add, :remove, :deferred).all?(&:empty?) && !b[:braked]
      end
      (result[:errors] || []).each { |e| lines << "ERROR #{e}" }
      lines
    end

    def log(message)
      Rails.logger.info("[discourse-siwe-auth] badge mirror: #{message}")
    end

    # ---- adapters ----------------------------------------------------------

    # Badge <-> token mapping, absence counters and flags in the plugin store.
    # No table and no migration.
    class RecordStore
      # namespace: prefix for every key. Empty in production; the staging
      # acceptance script uses its own so it can never see or move real records.
      def initialize(namespace: '')
        @ns = namespace.to_s
      end

      def records
        prefix = PluginStoreRow.sanitize_sql_like("#{@ns}#{RECORD_PREFIX}")
        keys = PluginStoreRow.where(plugin_name: STORE).where('key LIKE ?', "#{prefix}%").pluck(:key)
        return {} if keys.empty?

        PluginStore.get_all(STORE, keys).each_with_object({}) do |(_key, value), out|
          record = value.to_h.deep_symbolize_keys
          out[record[:token_id].to_i] = record if record[:token_id]
        end
      end

      def save_record(record)
        PluginStore.set(STORE, "#{@ns}#{RECORD_PREFIX}#{record[:token_id]}", record)
      end

      def meta
        (PluginStore.get(STORE, "#{@ns}#{META_KEY}") || {}).to_h.symbolize_keys
      end

      def save_meta(hash)
        PluginStore.set(STORE, "#{@ns}#{META_KEY}", hash)
      end

      def pending
        raw = PluginStore.get(STORE, "#{@ns}#{PENDING_KEY}") || {}
        raw.each_with_object({}) do |(token, counts), out|
          out[token.to_s] = counts.each_with_object({}) { |(id, n), h| h[id.to_i] = n.to_i }
        end
      end

      def save_pending(value)
        PluginStore.set(STORE, "#{@ns}#{PENDING_KEY}", value)
      end

      def hold?
        PluginStore.get(STORE, "#{@ns}#{HOLD_KEY}") == true
      end

      def set_hold(value)
        PluginStore.set(STORE, "#{@ns}#{HOLD_KEY}", value ? true : false)
      end
    end

    # Reads and writes Badge rows. Only called from enforce mode for writes.
    class BadgeStore
      READ = %i[name description long_description enabled badge_type_id badge_grouping_id listable allow_title multiple_grant image_upload_id].freeze

      def snapshots(records)
        ids = records.values.map { |r| r[:badge_id] }.compact
        rows = Badge.where(id: ids).index_by(&:id)
        records.each_with_object({}) do |(token, record), out|
          row = record[:badge_id] && rows[record[:badge_id].to_i]
          # [] reads the column; the description readers are overridden for i18n.
          out[token] = row && READ.each_with_object({}) { |attr, h| h[attr] = row[attr] }
        end
      end

      def taken_names
        Set.new(Badge.pluck(:name).map { |n| BadgeContent.name_key(n) })
      end

      def grouping_id(create:)
        grouping = BadgeGrouping.find_by(name: BadgeCatalog::GROUPING_NAME)
        return grouping.id if grouping
        return nil unless create

        BadgeGrouping.create!(
          name: BadgeCatalog::GROUPING_NAME,
          description: 'Badges mirrored from the Society Protocol outpost.',
          position: (BadgeGrouping.maximum(:position) || 0) + 1,
        ).id
      end

      def create(attrs)
        Badge.create!(attrs.merge(system: false, query: nil, trigger: Badge::Trigger::None, show_posts: false, target_posts: false)).id
      end

      def update(badge_id, attrs)
        Badge.find(badge_id).update!(attrs)
      end
    end

    # UserBadge reads, and grants/revokes through BadgeGranter. Writes only in
    # enforce mode (the orchestrator never calls them in log mode either).
    class GrantStore
      def initialize(writable)
        @writable = writable
      end

      def holders(badge_id)
        Set.new(UserBadge.where(badge_id: badge_id).pluck(:user_id))
      end

      def grant(badge_id, user_id, suppress:)
        return false unless @writable

        badge = Badge.find_by(id: badge_id)
        user = User.find_by(id: user_id)
        return false unless badge && user

        existed = UserBadge.exists?(badge_id: badge_id, user_id: user_id)
        user_badge = BadgeGranter.grant(badge, user, granted_by: Discourse.system_user, suppress_notification: suppress)
        audit('granted', user, badge) if user_badge && !existed
        !!user_badge
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        UserBadge.exists?(badge_id: badge_id, user_id: user_id) # a login job granted it first
      end

      def revoke(badge_id, user_id)
        return unless @writable

        UserBadge.where(badge_id: badge_id, user_id: user_id).includes(:user, :badge).each do |user_badge|
          user = user_badge.user
          badge = user_badge.badge
          BadgeGranter.revoke(user_badge)
          audit('revoked', user, badge) if user && badge
        end
      end

      private

      def audit(action, user, badge)
        StaffActionLogger.new(Discourse.system_user).log_custom(
          'siwe_badge_sync',
          subject: user.username,
          details: "#{action} badge #{badge.name} #{action == 'granted' ? 'to' : 'from'} #{user.username} (on-chain holdings)",
        )
      end
    end
  end
end
