# frozen_string_literal: true

# Point every forum siwe user at the Light Account their wallet owns.
# Posts and groups stay on the same Discourse user.
#
# For each siwe UserAssociatedAccount whose uid is an EOA E, derives
# S = LightAccountFactory.getAddress(E, 0) and moves the row to S
# (EIP-55 checksummed, as the strategy's uid). Also rewrites the address in
# the user's wallet_address custom field, the row's info json and a
# wallet-style display name, and stores E in siwe_owner_address.
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
  info = (account.info || {}).dup
  %w[nickname name].each { |k| info[k] = to if LA.same_address?(info[k], from) }
  account.update!(provider_uid: to, info: info)

  cf_wallet = user.custom_fields["wallet_address"]
  if cf_wallet.blank? || LA.same_address?(cf_wallet, from) || LA.same_address?(cf_wallet, to)
    user.custom_fields["wallet_address"] = to.downcase
  end
  user.custom_fields["siwe_owner_address"] = from.downcase
  user.save_custom_fields(true)

  if (user.custom_fields["preferred_identity"] || "wallet") == "wallet" &&
       user.name == REWRITE.short_wallet(from)
    user.update!(name: REWRITE.short_wallet(to))
  end
end

by_id = accounts.index_by(&:id)
ActiveRecord::Base.transaction do
  plan.each do |p|
    account = by_id[p[:row][:id]]
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
      original, newer = [account, other].sort_by { |a| [a.user.created_at, a.user.id] }
      newer.destroy!
      swap_address.call(original, original.user, p[:from], p[:to])
      UserMerger.new(newer.user, original.user, Discourse.system_user).merge!
      puts "merged user #{newer.user_id} into #{original.user_id}"
    end
  end
end

written = plan.count { |p| %i[rewrite recase adopt].include?(p[:status]) }
puts "\nAPPLIED: #{written} accounts rewritten#{merge ? ", #{duplicates.size} duplicates merged" : ''}."
