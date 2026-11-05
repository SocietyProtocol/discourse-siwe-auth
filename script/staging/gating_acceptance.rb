# frozen_string_literal: true

# Staging acceptance test for token-gated categories. Run INSIDE the staging
# forum container (never prod; it refuses to run if the badges chain is not
# Sepolia):
#
#   cd /var/www/discourse && su discourse -c 'RAILS_ENV=production bundle exec rails runner plugins/discourse-siwe-auth/script/staging/gating_acceptance.rb'
#
# Uses the Sepolia rehearsal users (rehearsal_alice holds badge 71,
# rehearsal_bob holds 72). Creates, checks and removes its own groups,
# category, topic and API key.
require 'net/http'

SEPOLIA_BADGES = '0x12406bb6d11cb641e100f1d8595c0c5e63f0bd47'
abort 'refusing: the badges contract is not the Sepolia one (this script is for staging only)' unless SiteSetting.siwe_society_badges_contract.to_s.downcase == SEPOLIA_BADGES

FAILS = []
def check(label, ok)
  puts "#{ok ? 'PASS' : 'FAIL'}  #{label}"
  FAILS << label unless ok
end

def http(path, username: nil, key: nil, method: :get)
  uri = URI("http://127.0.0.1:8080#{path}")
  req = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
  req['X-Forwarded-Proto'] = 'https'
  req['Host'] = Discourse.current_hostname
  if username
    req['Api-Key'] = key
    req['Api-Username'] = username
  end
  Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
end

G_GOLD = 'f4-gold'
G_OTHER = 'f4-other'
SLUG = 'f4-gold-lounge'
WORD = "zzgatedcanary#{SecureRandom.hex(3)}"
# Search endpoints echo the query back, so leaks are detected by the topic text, not the query.
TITLE_MARK = "Gated canary"
BODY_MARK = "Secret body"
def leaked?(body)
  body.include?(TITLE_MARK) || body.include?(BODY_MARK)
end
saved = {}
%w[siwe_society_badges_chain_id siwe_group_badge_mapping siwe_gating_config siwe_group_sync_removal_confirmations siwe_group_sync_removal_floor].each { |s| saved[s] = SiteSetting.public_send(s) }
alice = User.find_by!(username: 'rehearsal_alice')
bob = User.find_by!(username: 'rehearsal_bob')
admin = User.where(admin: true, active: true).where.not(id: Discourse.system_user.id).first!
api_key = nil
topic = nil

begin
  SiteSetting.siwe_society_badges_chain_id = 11_155_111
  SiteSetting.siwe_group_badge_mapping = "71:#{G_GOLD}|72:#{G_OTHER}"
  SiteSetting.siwe_group_sync_removal_confirmations = 2
  SiteSetting.siwe_group_sync_removal_floor = 3
  SiteSetting.siwe_gating_config = <<~YAML
    groups:
      #{G_GOLD}:
        full_name: F4 Gold
      #{G_OTHER}: {}
    categories:
      #{SLUG}:
        name: F4 Gold Lounge
        access:
          #{G_GOLD}: full
  YAML

  cfg = DiscourseSiwe::GatingRunner.config
  check 'config parses with no errors', cfg.errors.empty?

  plan = DiscourseSiwe::GatingRunner.plan(cfg)
  check 'first plan creates 2 groups, a category and its permissions', plan.actions.map(&:type).sort == %i[create_category create_group create_group set_permissions]
  check 'dry run changed nothing', !Group.exists?(name: G_GOLD) && !Category.exists?(slug: SLUG)

  DiscourseSiwe::GatingRunner.apply(plan, cfg)
  category = Category.find_by!(slug: SLUG)
  check 'category was created restricted', category.read_restricted
  check 'category permissions are the gold group (full) and staff', category.category_groups.map { |c| [c.group.name, c.permission_type] }.sort == [[G_GOLD, 1], ['staff', 1]].sort
  check 'groups are closed (no join, no requests)', Group.where(name: [G_GOLD, G_OTHER]).all? { |g| !g.public_admission && !g.public_exit && !g.allow_membership_requests }
  check 'second plan is empty (idempotent)', DiscourseSiwe::GatingRunner.plan(DiscourseSiwe::GatingRunner.config).actions.empty?

  # Drift: someone opens the category to a stray group; provision puts it back.
  stray = Group.find_by!(name: G_OTHER)
  category.set_permissions(Group.find_by!(name: G_GOLD).id => :full, stray.id => :full, Group::AUTO_GROUPS[:staff] => :full)
  category.save!
  drift = DiscourseSiwe::GatingRunner.plan
  check 'drift is detected', drift.actions.map(&:type) == [:set_permissions]
  DiscourseSiwe::GatingRunner.apply(drift, DiscourseSiwe::GatingRunner.config)
  check 'drift is corrected', DiscourseSiwe::GatingRunner.plan.actions.empty?

  # Enforce the chain-driven membership.
  result = DiscourseSiwe::GroupSyncRunner.run(mode: 'enforce')
  check "badge sync read the chain (#{result[:status]})", result[:status] == :ok
  gold = Group.find_by!(name: G_GOLD)
  other = Group.find_by!(name: G_OTHER)
  check 'alice (badge 71) is in the gold group', gold.users.exists?(alice.id)
  check 'bob (badge 72) is NOT in the gold group', !gold.users.exists?(bob.id)
  check 'bob is in the other group', other.users.exists?(bob.id)

  # A hidden topic in the gated category.
  topic = PostCreator.create!(admin, title: "Gated canary #{WORD} topic", raw: "Secret body #{WORD} for gold members only", category: category.id).topic
  api_key = ApiKey.create!(description: 'f4 acceptance (temp)', created_by: admin)
  k = api_key.key

  as_alice = http("/t/#{topic.id}.json", username: alice.username, key: k)
  as_bob = http("/t/#{topic.id}.json", username: bob.username, key: k)
  anon = http("/t/#{topic.id}.json")
  check "holder (alice) can read the topic (#{as_alice.code})", as_alice.code == '200'
  check "non-holder (bob) is refused (#{as_bob.code})", %w[403 404].include?(as_bob.code) && !leaked?(as_bob.body)
  check "anonymous is refused (#{anon.code})", %w[403 404].include?(anon.code) && !leaked?(anon.body)

  cat_bob = http("/c/#{category.id}/show.json", username: bob.username, key: k)
  check "category page refused for bob (#{cat_bob.code})", %w[403 404].include?(cat_bob.code)
  cats_bob = http('/categories.json', username: bob.username, key: k)
  check 'category absent from /categories.json for bob', !cats_bob.body.include?(SLUG)
  cats_alice = http('/categories.json', username: alice.username, key: k)
  check 'category present in /categories.json for alice', cats_alice.body.include?(SLUG)

  Jobs.run_immediately!
  SearchIndexer.index(topic, force: true) rescue nil
  topic.posts.each { |p| SearchIndexer.index(p, force: true) rescue nil }
  %w[/latest.json /latest.rss /search.json?q=%s /search?q=%s /tags.json].each do |path|
    path = path.sub('%s', WORD)
    r_bob = http(path, username: bob.username, key: k)
    r_anon = http(path)
    check "no leak of the topic at #{path.split('?').first} (bob/anon)", !leaked?(r_bob.body) && !leaked?(r_anon.body)
  end
  search_alice = http("/search.json?q=#{WORD}", username: alice.username, key: k)
  check 'search finds the topic for alice (leak checks are meaningful)', search_alice.body.include?(TITLE_MARK)

  join = http("/groups/#{G_GOLD}/join", username: bob.username, key: k, method: :post)
  check "bob cannot join the gold group (#{join.code})", join.code != '200' && !gold.reload.users.exists?(bob.id)

  # A non-holder added by hand is removed on the second enforce, then loses access.
  gold.add(bob)
  check 'bob (manually added) can read while a member', http("/t/#{topic.id}.json", username: bob.username, key: k).code == '200'
  DiscourseSiwe::GroupSyncRunner.run(mode: 'enforce')
  check 'first enforce only defers the removal', gold.reload.users.exists?(bob.id)
  DiscourseSiwe::GroupSyncRunner.run(mode: 'enforce')
  check 'second enforce removes the non-holder', !gold.reload.users.exists?(bob.id)
  check 'removed member loses access immediately', %w[403 404].include?(http("/t/#{topic.id}.json", username: bob.username, key: k).code)

  # Staff who are not holders are never removed.
  gold.add(admin)
  2.times { DiscourseSiwe::GroupSyncRunner.run(mode: 'enforce') }
  check 'a staff member who holds no badge is not removed', gold.reload.users.exists?(admin.id)
  gold.remove(admin)

  # Audit must flag a hand-added non-holder and pass when clean.
  gold.add(bob)
  audit = DiscourseSiwe::GatingRunner.audit_report
  check 'audit fails while a non-holder is in the gold group', !audit[:ok] && audit[:groups][G_GOLD][:lose_access].include?(bob.username)
  gold.remove(bob)
  clean = DiscourseSiwe::GatingRunner.audit_report
  check "audit passes when only holders remain (#{clean[:blockers].join('; ')})", clean[:ok]

  # A dead RPC removes nobody.
  keep = SiteSetting.siwe_society_badges_rpc_url
  SiteSetting.siwe_society_badges_rpc_url = 'http://127.0.0.1:9/'
  before = gold.reload.user_ids.sort
  2.times { DiscourseSiwe::GroupSyncRunner.run(mode: 'enforce') }
  check 'simulated RPC outage removes no one', gold.reload.user_ids.sort == before
  SiteSetting.siwe_society_badges_rpc_url = keep
ensure
  topic&.destroy rescue nil
  Category.find_by(slug: SLUG)&.destroy rescue nil
  Group.where(name: [G_GOLD, G_OTHER]).destroy_all rescue nil
  api_key&.destroy rescue nil
  saved.each { |name, value| SiteSetting.public_send("#{name}=", value) }
  PluginStore.remove('discourse-siwe-auth', 'group_sync_pending') rescue nil
  puts '---'
  puts FAILS.empty? ? 'ALL PASSED' : "FAILED (#{FAILS.size}): #{FAILS.join(' | ')}"
end
exit(FAILS.empty? ? 0 : 1)
