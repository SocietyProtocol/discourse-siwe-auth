# frozen_string_literal: true

# Staging acceptance test for the on-chain badge mirror (F1), run against real
# Discourse models. It is a rails runner script with assertions; it exits
# non-zero on the first failed assertion and always cleans up after itself.
#
# Run it on STAGING only, inside the forum container (it creates throw-away
# users, badges and grants, and briefly disables the system badges before
# restoring them):
#
#   cd /var/www/discourse
#   SIWE_ACCEPTANCE_OK=staging RAILS_ENV=production LOAD_PLUGINS=1 bundle exec rails runner \
#     plugins/discourse-siwe-auth/script/staging/badge_mirror_acceptance.rb
#
# Optional: ACCEPT_IMAGE_URL=https://.../small.png also exercises the real
# download + upload path (needs outbound HTTPS).
#
# What it does NOT touch: the real mirror state. It uses its own plugin-store
# namespace ("acceptance:"), its own token ids (9000001..9000004), a fake
# catalog and fake chain balances, and users it creates itself.
#
# Covered: catalog create and idempotency (a second run changes nothing),
# null metadata keeps what we have, update, name collision (stable), grant,
# notification suppression then notification, revoke (confirmation, and the
# notification is removed), unknown balance never revokes, a source error
# changes nothing, archive (never deleted), mode log writes nothing, the
# eligible-user filter, SSRF refusal in the image fetch, the login debounce,
# and the system badge disable (dry run, apply, idempotent, restore).

require 'securerandom'
require 'set'

unless ENV['SIWE_ACCEPTANCE_OK'] == 'staging'
  abort 'Refusing to run: this script creates test data. Run it on staging only, with SIWE_ACCEPTANCE_OK=staging.'
end

module BadgeMirrorAcceptance
  Mirror = DiscourseSiwe::BadgeMirror
  Runner = DiscourseSiwe::BadgeMirrorRunner
  NS = 'acceptance:'
  TOKENS = { a: 9_000_001, b: 9_000_002, c: 9_000_003, d: 9_000_004 }.freeze
  PASSED = []

  module_function

  def check(name, condition, detail = nil)
    raise "FAILED: #{name}#{detail ? " (#{detail})" : ''}" unless condition

    PASSED << name
    puts "  ok  #{name}"
  end

  def store
    Runner::RecordStore.new(namespace: NS)
  end

  def row(key, extra = {})
    {
      'id' => TOKENS.fetch(key).to_s, 'name' => "Acceptance #{key}", 'isOfficial' => true, 'isCommunity' => false,
      'uri' => "ipfs://acceptance/#{key}",
      'metadata' => { 'description' => "Acceptance badge #{key}", 'imageUrl' => nil }
    }.merge(extra)
  end

  # chain: { address => { token_id => Integer|nil } }
  def build(rows:, users:, chain:, mode: 'enforce', ownership: nil, catalog: :rows, config: {})
    ownership ||= lambda do |addresses, _ids|
      addresses.each_with_object({}) { |address, out| out[address] = (chain[address] || {}).dup }
    end
    Mirror.new(
      catalog: catalog == :rows ? -> { rows } : catalog,
      store: store, badges: Runner::BadgeStore.new, grants: Runner::GrantStore.new(mode == 'enforce'),
      images: ->(_url) { nil }, users: users, ownership: ownership,
      config: Mirror.config(**{ confirmations: 2, floor: 5, percent: 20 }.merge(config)),
      log: ->(_message) {},
    )
  end

  def make_user(n)
    suffix = SecureRandom.hex(4)
    user = User.new(
      username: "siweacc#{n}#{suffix}", email: "siweacc#{n}#{suffix}@siwe-acceptance.example.com",
      password: "Acc-#{SecureRandom.hex(10)}", active: true, approved: true, trust_level: 1
    )
    user.save!
    user
  end

  def snapshot_counts(badge_ids)
    {
      badges: Badge.count, badge_updated: Badge.where(id: badge_ids).pluck(:id, :updated_at).sort,
      user_badges: UserBadge.count, uploads: Upload.count, notifications: Notification.count,
      store_rows: PluginStoreRow.where(plugin_name: Runner::STORE).where('key LIKE ?', "#{NS}%").pluck(:key, :value).sort
    }
  end

  def run
    puts "Badge mirror acceptance (Discourse #{Discourse::VERSION::STRING})"
    users = []
    created_grouping = nil
    restore_system = []
    begin
      check('enable_badges is on', SiteSetting.enable_badges)
      purge_namespace # leftovers of an aborted earlier run
      created_grouping = !BadgeGrouping.exists?(name: DiscourseSiwe::BadgeCatalog::GROUPING_NAME)

      u1, u2, u3, u4 = Array.new(4) { |i| make_user(i + 1) }
      users.push(u1, u2, u3, u4)
      addr = ->(n) { "0x#{n.to_s(16).rjust(2, '0') * 20}" }
      wallets = { u1 => addr.call(0xa1), u2 => addr.call(0xa2), u3 => addr.call(0xa3), u4 => addr.call(0xa4) }
      member = ->(*list) { list.map { |u| { id: u.id, username: u.username, addresses: [wallets[u]] } } }
      a, b, c, d = TOKENS.values_at(:a, :b, :c, :d)

      # --- catalog -----------------------------------------------------------
      puts 'catalog'
      existing_name = Badge.where(system: true).order(:id).pick(:name) || 'Welcome'
      rows = [row(:a), row(:b), row(:c, 'name' => existing_name), row(:d)]
      chain = {}
      report = build(rows: rows, users: [], chain: chain).run(mode: 'enforce')
      check('first run creates the four badges', report[:catalog][:created].sort == TOKENS.values.sort, report[:catalog].inspect)
      records = store.records
      badges = TOKENS.values.map { |t| Badge.find(records[t][:badge_id]) }
      badge_ids = badges.map(&:id)
      check('badges are not system, have no query and are single grant',
            badges.all? { |x| !x.system && x.query.nil? && !x.multiple_grant && x.id >= 100 })
      check('badges are enabled, listable, official = Gold', badges.all? { |x| x.enabled && x.listable && x.badge_type_id == BadgeType::Gold })
      grouping = BadgeGrouping.find_by(name: DiscourseSiwe::BadgeCatalog::GROUPING_NAME)
      check('Society Protocol grouping exists and is used', grouping && badges.all? { |x| x.badge_grouping_id == grouping.id })
      check('description comes from metadata', Badge.find(records[a][:badge_id])[:description] == 'Acceptance badge a')
      long = Badge.find(records[a][:badge_id])[:long_description]
      check('long description names the token and is capped', long.include?(a.to_s) && long.length <= 1000)

      before = snapshot_counts(badge_ids)
      report = build(rows: rows, users: [], chain: chain).run(mode: 'enforce')
      after = snapshot_counts(badge_ids)
      check('second run reports no catalog change', (report[:catalog][:created] + report[:catalog][:updated] + report[:catalog][:archived]).empty?)
      check('second run changes no badge, grant, upload, notification or stored record',
            before.reject { |k, _| k == :store_rows } == after.reject { |k, _| k == :store_rows } &&
            before[:store_rows].map(&:first) == after[:store_rows].map(&:first))

      # name collision
      cname = Badge.find(records[c][:badge_id]).name
      check('colliding name gets the token suffix', cname == "#{existing_name} (##{c})", cname)
      build(rows: rows, users: [], chain: chain).run(mode: 'enforce')
      check('suffixed name is stable on the next run', Badge.find(records[c][:badge_id]).name == cname)

      # null metadata keeps, real change updates
      null_rows = rows.map { |r| r['id'] == a.to_s ? r.merge('metadata' => nil) : r }
      build(rows: null_rows, users: [], chain: chain).run(mode: 'enforce')
      check('null metadata keeps the description', Badge.find(records[a][:badge_id])[:description] == 'Acceptance badge a')
      changed = rows.map { |r| r['id'] == a.to_s ? r.merge('metadata' => { 'description' => 'Changed <b>text</b> https://evil.test', 'imageUrl' => nil }) : r }
      report = build(rows: changed, users: [], chain: chain).run(mode: 'enforce')
      check('a changed description is updated and sanitised',
            report[:catalog][:updated] == [a] && Badge.find(records[a][:badge_id])[:description] == 'Changed text', report[:catalog].inspect)
      manual = Badge.find(records[a][:badge_id])
      manual.update!(name: 'Manual edit')
      build(rows: changed, users: [], chain: chain).run(mode: 'enforce')
      check('a manual edit of a synced badge is overwritten', Badge.find(records[a][:badge_id]).name == 'Acceptance a')

      # --- holders -------------------------------------------------------------
      puts 'holders'
      badge_a = records[a][:badge_id]
      notifications = ->(user) { Notification.where(user_id: user.id, notification_type: Notification.types[:granted_badge]).count }
      chain = { wallets[u1] => { a => 1 }, wallets[u2] => { a => 1, b => 3 }, wallets[u3] => { a => 0 }, wallets[u4] => {} }
      report = build(rows: changed, users: member.call(u1, u2, u3, u4), chain: chain).run(mode: 'enforce')
      check('holders are granted', UserBadge.exists?(user_id: u1.id, badge_id: badge_a) && UserBadge.exists?(user_id: u2.id, badge_id: badge_a) &&
                                   UserBadge.exists?(user_id: u2.id, badge_id: records[b][:badge_id]), report.inspect)
      check('non-holders are not granted', !UserBadge.exists?(user_id: u3.id, badge_id: badge_a) && !UserBadge.exists?(user_id: u4.id))
      check('the backfill is silent', notifications.call(u1).zero? && notifications.call(u2).zero?)
      check('granted by the system user', UserBadge.where(user_id: u1.id, badge_id: badge_a).first.granted_by_id == Discourse.system_user.id)
      check('backfilled flag is stored', store.records[a][:backfilled] == true)

      chain[wallets[u3]] = { a => 2 }
      build(rows: changed, users: member.call(u1, u2, u3, u4), chain: chain).run(mode: 'enforce')
      user_badge = UserBadge.find_by(user_id: u3.id, badge_id: badge_a)
      check('a new holder after the backfill is granted and notified', user_badge && user_badge.notification_id && notifications.call(u3) == 1)

      # revoke needs two runs; unknown never revokes
      chain[wallets[u1]] = { a => 0 }
      chain[wallets[u2]] = { a => nil, b => 3 }
      build(rows: changed, users: member.call(u1, u2, u3, u4), chain: chain).run(mode: 'enforce')
      check('first absence only defers the revoke', UserBadge.exists?(user_id: u1.id, badge_id: badge_a))
      build(rows: changed, users: member.call(u1, u2, u3, u4), chain: chain).run(mode: 'enforce')
      check('second absence revokes', !UserBadge.exists?(user_id: u1.id, badge_id: badge_a))
      3.times { build(rows: changed, users: member.call(u1, u2, u3, u4), chain: chain).run(mode: 'enforce') }
      check('an unknown balance never revokes', UserBadge.exists?(user_id: u2.id, badge_id: badge_a))

      chain[wallets[u3]] = { a => 0 }
      2.times { build(rows: changed, users: member.call(u1, u2, u3, u4), chain: chain).run(mode: 'enforce') }
      check('revoking removes the grant and its notification', !UserBadge.exists?(user_id: u3.id, badge_id: badge_a) && notifications.call(u3).zero?)

      # source errors change nothing
      before = snapshot_counts(badge_ids)
      boom = ->(_addresses, _ids) { raise DiscourseSiwe::BadgeOwnership::SourceError, 'wrong chain' }
      3.times { build(rows: changed, users: member.call(u1, u2, u3, u4), chain: chain, ownership: boom).run(mode: 'enforce') }
      check('a chain error changes no grant', before[:user_badges] == UserBadge.count)
      failing = -> { raise DiscourseSiwe::SubgraphClient::Error, 'gateway HTTP 500' }
      chain[wallets[u2]] = { a => 0, b => 0 }
      3.times { build(rows: changed, users: member.call(u1, u2, u3, u4), chain: chain, catalog: failing).run(mode: 'enforce') }
      check('a catalog error blocks revokes', UserBadge.exists?(user_id: u2.id, badge_id: badge_a))
      check('and raises the revoke hold', store.hold?)
      build(rows: changed, users: member.call(u1, u2, u3, u4), chain: chain).run(mode: 'enforce')
      check('a clean full run clears the hold', !store.hold?)
      chain[wallets[u2]] = { a => 1, b => 1 }
      build(rows: changed, users: member.call(u1, u2, u3, u4), chain: chain).run(mode: 'enforce')

      # --- archive ---------------------------------------------------------------
      puts 'archive'
      without_d = changed.reject { |r| r['id'] == d.to_s }
      build(rows: without_d, users: [], chain: chain).run(mode: 'enforce')
      check('one missing run does not archive', Badge.find(records[d][:badge_id]).enabled)
      build(rows: without_d, users: [], chain: chain).run(mode: 'enforce')
      archived = Badge.find_by(id: records[d][:badge_id])
      check('two missing runs archive the badge (disabled, not deleted)', archived && !archived.enabled && store.records[d][:archived])
      build(rows: changed, users: [], chain: chain).run(mode: 'enforce')
      check('it comes back when it reappears', Badge.find(records[d][:badge_id]).enabled && !store.records[d][:archived])

      # --- mode log -----------------------------------------------------------------
      puts 'mode log'
      before = snapshot_counts(badge_ids)
      log_rows = changed.map { |r| r['id'] == b.to_s ? r.merge('name' => 'Renamed on chain') : r } + [row(:a, 'id' => '9000099', 'name' => 'Would be new')]
      chain[wallets[u4]] = { a => 5, b => 1 }
      report = build(rows: log_rows, users: member.call(u1, u2, u3, u4), chain: chain, mode: 'log').run(mode: 'log')
      after = snapshot_counts(badge_ids)
      check('log mode writes nothing', before == after, "report #{report.inspect}")
      check('but reports what it would do', report[:catalog][:created].include?(9_000_099) && report[:badges].values.any? { |x| x[:add].include?(u4.username) })

      # --- eligible users -------------------------------------------------------------
      puts 'eligible users'
      users.each { |u| u.custom_fields['wallet_address'] = wallets[u]; u.save_custom_fields }
      u3.update!(suspended_till: 1.day.from_now, suspended_at: Time.zone.now)
      u4.update!(silenced_till: 1.day.from_now)
      eligible = Set.new(Runner.eligible_users.map { |x| x[:id] })
      check('active members with a wallet are eligible', eligible.include?(u1.id) && eligible.include?(u2.id))
      check('suspended and silenced members are not', !eligible.include?(u3.id) && !eligible.include?(u4.id))
      u3.update!(suspended_till: nil, suspended_at: nil)
      u4.update!(silenced_till: nil)

      # --- image fetch policy -----------------------------------------------------------
      puts 'image'
      check('loopback is refused', Runner.fetch_image('https://127.0.0.1/badge.png').nil?)
      check('cloud metadata address is refused', Runner.fetch_image('https://169.254.169.254/latest/meta-data/').nil?)
      check('private network is refused', Runner.fetch_image('https://10.0.0.1/badge.png').nil?)
      if ENV['ACCEPT_IMAGE_URL'].present?
        image = Runner.fetch_image(ENV['ACCEPT_IMAGE_URL'])
        check('a real image is downloaded and uploaded', image && Upload.exists?(id: image[:upload_id]))
      else
        puts '  --  ACCEPT_IMAGE_URL not set: real download not exercised'
      end

      # --- debounce -------------------------------------------------------------------------
      puts 'login debounce'
      check('a never-synced member is due', Runner.login_due?(u1.id))
      Runner.mark_synced(u1.id)
      check('a just-synced member is not due', !Runner.login_due?(u1.id))
      UserCustomField.where(user_id: u1.id, name: Runner::SYNCED_FIELD).update_all(value: (Time.now.to_i - 4000).to_s)
      check('an hour later they are due again', Runner.login_due?(u1.id))

      # --- system badges ----------------------------------------------------------------------
      puts 'system badges'
      restore_system = Badge.where(system: true, enabled: true).pluck(:id)
      mirrored_enabled = Badge.where(id: badge_ids, enabled: true).count
      dry = DiscourseSiwe::SystemBadges.disable!(dry_run: true)
      check('dry run changes nothing', Badge.where(system: true, enabled: true).count == restore_system.size && dry[:dry_run])
      DiscourseSiwe::SystemBadges.disable!(dry_run: false)
      check('apply disables every system badge', Badge.where(system: true, enabled: true).count.zero?)
      check('enable_badges is still on', SiteSetting.enable_badges)
      check('mirrored badges are untouched', Badge.where(id: badge_ids, enabled: true).count == mirrored_enabled)
      again = DiscourseSiwe::SystemBadges.disable!(dry_run: false)
      check('a second apply is a no-op', again[:disabled].empty?)
      before_grants = UserBadge.count
      purge = DiscourseSiwe::SystemBadges.purge_grants!(dry_run: true)
      check('purge dry run deletes nothing and reports counts', UserBadge.count == before_grants && purge[:dry_run] && purge[:user_badges].is_a?(Integer))

      puts "\nAll #{PASSED.size} checks passed."
    ensure
      puts "\ncleaning up"
      cleanup(users, restore_system, created_grouping)
    end
  end

  # Deletes the acceptance badges (their grants and notifications go with
  # them) and the acceptance plugin-store rows.
  def purge_namespace
    store.records.each_value { |record| Badge.find_by(id: record[:badge_id])&.destroy }
    PluginStoreRow.where(plugin_name: Runner::STORE).where('key LIKE ?', "#{NS}%").delete_all
  end

  def cleanup(users, restore_system, created_grouping)
    Badge.where(id: restore_system).find_each { |badge| badge.update!(enabled: true) } if restore_system.any?

    purge_namespace
    UserCustomField.where(user_id: users.map(&:id), name: Runner::SYNCED_FIELD).delete_all

    users.each do |user|
      begin
        UserDestroyer.new(Discourse.system_user).destroy(user, quiet: true) || user.destroy
      rescue StandardError => e
        puts "  could not delete #{user.username}: #{e.class}"
      end
    end
    BadgeGrouping.where(name: DiscourseSiwe::BadgeCatalog::GROUPING_NAME).destroy_all if created_grouping && !Badge.where(badge_grouping_id: BadgeGrouping.where(name: DiscourseSiwe::BadgeCatalog::GROUPING_NAME).select(:id)).exists?
    UserBadge.ensure_consistency!
    puts '  done'
  end
end

begin
  BadgeMirrorAcceptance.run
rescue StandardError => e
  puts "\n#{e.message}"
  puts e.backtrace.first(5)
  exit 1
end
