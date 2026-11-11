# frozen_string_literal: true

# Point every forum siwe user at the Light Account their wallet owns.
# Posts and groups stay on the same Discourse user.
#
# For each siwe UserAssociatedAccount whose uid is an EOA E, derives
# S = LightAccountFactory.getAddress(E, 0) and moves the row to S
# (EIP-55 checksummed, as the strategy's uid). Also rewrites the address in
# the user's wallet_address custom field and stores E in siwe_owner_address.
#
# Then renames what the login derived from E to what a fresh Light Account
# login would get: a display name that is E (in full or in the short
# 0x9ba7…7c3c form), a username Discourse cut from E, and nickname / name in
# the row's info json. Anything else (a chosen name, a Society or ENS name)
# is left alone. Rows an earlier run already moved are checked too, so a
# re-run fixes names that run left behind. The dry run lists every rename.
#
# Dry run by default. From the Discourse container, with this plugin checkout
# on disk (see README "Moving forum users to Light Accounts"):
#
#   rails runner /path/discourse-siwe-auth/script/rewrite_smart_account_users.rb
#   APPLY=1 rails runner /path/discourse-siwe-auth/script/rewrite_smart_account_users.rb
#
# Env:
#   APPLY=1             write the changes (in one transaction)
#   MERGE_DUPLICATES=1  with APPLY=1, merge a newer user already signed in as
#                       S into the original user via UserMerger
#   FORUM_ADDRESS_MAP   address map for the self-test (default: next to this
#                       script; flat or chain-keyed)
#   RPC_URL             JSON-RPC for the forum's chain, to skip contract
#                       wallets (default: siwe_ethereum_rpc_url)
#   SKIP_CODE_CHECK=1   run without an RPC (contract wallets get rewritten too)
#   SUSPECT_AFTER       ISO time; rows created later are left for review.
#                       Set it to the first deploy of a build with the Light
#                       Account login (8a4f838 or later): that login signs in
#                       as S without recording the owner, and an S that is
#                       not in the map would otherwise be rewritten to LA(S).
#   KEEP_USERNAMES=1    do not rename usernames cut from the old address
#                       (display names and info are still renamed)
#   NO_LIGHT_ACCOUNT_LOGIN_DEPLOYED=1
#                       with APPLY=1 and no SUSPECT_AFTER: confirm no such
#                       build ever ran on this forum

require "json"
require "set"
require "time"

plugin_root = File.expand_path("..", __dir__)
%w[eth_rpc light_account smart_account_rewrite].each do |file|
  load File.join(plugin_root, "lib/discourse_siwe/#{file}.rb")
end

LA = DiscourseSiwe::LightAccount
REWRITE = DiscourseSiwe::SmartAccountRewrite

apply = ENV["APPLY"] == "1"
merge = ENV["MERGE_DUPLICATES"] == "1"
keep_usernames = ENV["KEEP_USERNAMES"] == "1"
rpc_url = ENV["RPC_URL"].presence || DiscourseSiwe::EthRpc.rpc_url
suspect_after = ENV["SUSPECT_AFTER"].presence && Time.parse(ENV["SUSPECT_AFTER"])

map_path = ENV["FORUM_ADDRESS_MAP"].presence || File.join(__dir__, "forum-address-map.json")
pairs = REWRITE.address_pairs(JSON.parse(File.read(map_path)))
puts "self-test: #{REWRITE.self_test!(pairs)} pairs from #{map_path} match"

code_for =
  if ENV["SKIP_CODE_CHECK"] == "1"
    puts "WARNING: SKIP_CODE_CHECK=1, contract wallets are not detected"
    nil
  elsif rpc_url
    ->(address) { DiscourseSiwe::EthRpc.get_code(address, url: rpc_url) }
  else
    abort "No RPC: set RPC_URL (or siwe_ethereum_rpc_url), or SKIP_CODE_CHECK=1"
  end

accounts = UserAssociatedAccount.where(provider_name: "siwe").includes(:user).order(:id).to_a
owners = UserCustomField
  .where(name: "siwe_owner_address", user_id: accounts.map(&:user_id).compact)
  .pluck(:user_id, :value)
  .to_h

rows = accounts.map do |a|
  {
    id: a.id,
    user_id: a.user&.id,
    username: a.user&.username,
    uid: a.provider_uid,
    owner: owners[a.user_id],
    created_at: a.created_at,
  }
end
plan = REWRITE.plan(rows, code_for: code_for, suspect_after: suspect_after, known_pairs: pairs)

header = %w[status row user username from to note]
table = plan.map do |p|
  [p[:status], p[:row][:id], p[:row][:user_id], p[:row][:username], p[:from], p[:to], p[:note]].map(&:to_s)
end
widths = header.each_index.map { |i| ([header[i]] + table.map { |r| r[i] }).map(&:length).max }
puts(([header] + table).map { |r| r.each_with_index.map { |c, i| c.ljust(widths[i]) }.join("  ").rstrip })
counts = plan.group_by { |p| p[:status] }.map { |s, ps| "#{s}=#{ps.size}" }.join(" ")
puts "\n#{plan.size} siwe accounts: #{counts}"

duplicates = plan.select { |p| p[:status] == :duplicate }
duplicates.each do |p|
  a = p[:row]
  b = p[:other]
  puts "DUPLICATE: user #{a[:user_id]} (#{a[:username]}) signed in as #{a[:uid]}, " \
       "user #{b[:user_id]} (#{b[:username]}) already signed in as #{p[:to]}. " \
       "#{merge ? 'Will merge.' : 'Merge them (MERGE_DUPLICATES=1 or admin UI), then re-run.'}"
end

# Known Light Accounts are planned as already/adopt/recase; this must hold.
known_smarts = pairs.map { |_, smart| smart.downcase }.to_set
bad = plan.select { |p| %i[rewrite duplicate].include?(p[:status]) && known_smarts.include?(p[:from].downcase) }
abort "BUG: would rewrite known Light Accounts #{bad.map { |p| p[:from] }.join(', ')}" if bad.any?

by_id = accounts.index_by(&:id)

# With MERGE_DUPLICATES=1 the older of the two users survives.
survivor = lambda do |p|
  [by_id[p[:row][:id]], by_id[p[:other][:id]]].sort_by { |a| [a.user.created_at, a.user.id] }.first
end

# Names derived from the old address, per plan entry: [account, renames].
short_name = SiteSetting.siwe_society_enabled
username_for = ->(smart) { UserNameSuggester.suggest(smart) }
renames = plan.each_with_object({}) do |p, out|
  move = REWRITE.address_move(p, merge: merge)
  next unless move

  account = p[:status] == :duplicate ? survivor.call(p) : by_id[p[:row][:id]]
  user = account.user
  info = account.info || {}
  list = REWRITE.derived_renames(
    { name: user.name, username: user.username, info_nickname: info["nickname"], info_name: info["name"] },
    move[0], move[1], short_name: short_name, username_for: username_for,
  )
  list.reject! { |r| r[:field] == :username } if keep_usernames
  out[p[:row][:id]] = [account, list] if list.any?
end

rename_count = renames.values.sum { |_, list| list.size }
if rename_count.zero?
  puts "\nRENAMES: none (no name, username or info value is derived from an old address)"
else
  puts "\nRENAMES (values derived from the old address#{keep_usernames ? '; KEEP_USERNAMES=1, usernames kept' : ''}):"
  renames.each_value do |account, list|
    list.each do |r|
      puts "  user #{account.user_id} (#{account.user.username}) #{r[:field]}: #{r[:from]} -> #{r[:to]}"
    end
  end
  puts "#{rename_count} renames on #{renames.size} users"
end

unless apply
  puts "\nDRY RUN: nothing written. Re-run with APPLY=1 to write."
  exit
end

if suspect_after.nil? && ENV["NO_LIGHT_ACCOUNT_LOGIN_DEPLOYED"] != "1"
  abort "APPLY=1 needs SUSPECT_AFTER (first deploy of the Light Account login, 8a4f838 or later), " \
        "or NO_LIGHT_ACCOUNT_LOGIN_DEPLOYED=1 if no such build ever ran here"
end

if merge && duplicates.any? && !defined?(::UserMerger)
  abort "MERGE_DUPLICATES=1 but UserMerger is not available in this Discourse"
end

swap_address = lambda do |account, user, from, to|
  account.update!(provider_uid: to)

  cf_wallet = user.custom_fields["wallet_address"]
  if cf_wallet.blank? || LA.same_address?(cf_wallet, from) || LA.same_address?(cf_wallet, to)
    user.custom_fields["wallet_address"] = to.downcase
  end
  user.custom_fields["siwe_owner_address"] = from.downcase
  user.save_custom_fields(true)
end

# Display name and info json, inside the transaction. Usernames go through
# UsernameChanger after it commits (it enqueues a job that rewrites mentions).
rename_fields = lambda do |account, list|
  info = (account.info || {}).dup
  list.each do |r|
    case r[:field]
    when :name then account.user.update!(name: r[:to])
    when :info_nickname then info["nickname"] = r[:to]
    when :info_name then info["name"] = r[:to]
    end
  end
  account.update!(info: info) if info != (account.info || {})
end

ActiveRecord::Base.transaction do
  plan.each do |p|
    account = by_id[p[:row][:id]]
    renamed = renames[p[:row][:id]]
    rename_fields.call(*renamed) if renamed
    case p[:status]
    when :rewrite
      swap_address.call(account, account.user, p[:from], p[:to])
    when :adopt, :recase
      account.update!(provider_uid: p[:to]) if p[:to]
      if p[:owner]
        account.user.custom_fields["siwe_owner_address"] = p[:owner]
        account.user.save_custom_fields(true)
      end
    when :duplicate
      next unless merge

      other = by_id[p[:other][:id]]
      original = survivor.call(p)
      newer = original == account ? other : account
      newer.destroy!
      swap_address.call(original, original.user, p[:from], p[:to])
      UserMerger.new(newer.user, original.user, Discourse.system_user).merge!
      puts "merged user #{newer.user_id} into #{original.user_id}"
    end
  end
end

username_changes = 0
renames.each_value do |account, list|
  list.select { |r| r[:field] == :username }.each do |r|
    user = account.user.reload
    next if user.username == r[:to]

    to = UserNameSuggester.suggest(r[:to], current_username: user.username)
    unless UsernameChanger.change(user, to, Discourse.system_user)
      abort "username change failed for user #{user.id} (#{user.username} -> #{to}): " \
            "#{user.errors.full_messages.join(', ')}. Everything else is written; re-run to retry."
    end
    username_changes += 1
    puts "renamed user #{user.id}: #{r[:from]} -> #{to}"
  end
end

written = plan.count { |p| %i[rewrite recase adopt].include?(p[:status]) }
puts "\nAPPLIED: #{written} accounts rewritten#{merge ? ", #{duplicates.size} duplicates merged" : ''}, " \
     "#{rename_count - username_changes} names/info values and #{username_changes} usernames renamed."
