# frozen_string_literal: true

# Transfer every forum siwe user to the Light Account their wallet owns.
# Posts, groups, badges and settings stay on the same Discourse user.
#
# This is the same tool as `rake siwe:smart_accounts:transfer`, for a forum
# that does not run this plugin version yet: it loads the code from the
# checkout it sits in. README "Transferring users to smart accounts" lists
# everything it moves, the procedure and the rollback.
#
# Dry run by default. From the Discourse container, as the discourse user:
#
#   rails runner /path/discourse-siwe-auth/script/rewrite_smart_account_users.rb
#   APPLY=1 rails runner /path/discourse-siwe-auth/script/rewrite_smart_account_users.rb
#   VERIFY=1 rails runner /path/discourse-siwe-auth/script/rewrite_smart_account_users.rb
#
# Env:
#   APPLY=1             back up, write, then verify (exit 1 if an account is
#                       left on an old wallet)
#   VERIFY=1            only the read-only verification
#   RESTORE_SQL=<run>   only print the rollback SQL of that backup run
#   MERGE_DUPLICATES=1  merge a user who already signed in as the Light
#                       Account into the original user (UserMerger)
#   FULL_BACKUP_TAKEN=1 with APPLY=1, confirms a full `discourse backup`
#                       exists; required when a merge would happen
#   FORUM_ADDRESS_MAP   address map for the self-test (default: next to this
#                       script; flat or chain-keyed)
#   RPC_URL             JSON-RPC to tell contract wallets from EOAs
#                       (default: siwe_ethereum_rpc_url)
#   SKIP_CODE_CHECK=1   run without an RPC (contract wallets get rewritten too)
#   SUSPECT_AFTER       ISO time with Z or an offset (no zone: UTC); rows
#                       created later with no proof of their
#                       owner are left for review. Set it to the first deploy
#                       of a build with the Light Account login (8a4f838 or
#                       later): 8a4f838 itself signed in as S without
#                       recording the owner, and an S that is not in the map
#                       would otherwise be rewritten to LA(S).
#   NO_LIGHT_ACCOUNT_LOGIN_DEPLOYED=1
#                       with APPLY=1 and no SUSPECT_AFTER: confirm nobody
#                       ever signed in through such a build on this forum
#   REVIEWED_ROWS       comma-separated row ids of `review` rows you checked
#                       and accept as they are
#   KEEP_USERNAMES=1    do not rename usernames cut from the old address
#                       (display names and info are still renamed)
#
# SUSPECT_AFTER, REVIEWED_ROWS, KEEP_USERNAMES, MERGE_DUPLICATES and
# SKIP_CODE_CHECK change the plan: give the dry run, the apply and the
# verify the same ones.

plugin_root = File.expand_path("..", __dir__)
# Load this checkout's code even when an older plugin version is running.
verbose = $VERBOSE
$VERBOSE = nil
%w[eth_rpc light_account smart_account_transfer_runner].each do |file|
  load File.join(plugin_root, "lib/discourse_siwe/#{file}.rb")
end
$VERBOSE = verbose

unless ENV["RESTORE_SQL"].to_s.strip.empty?
  exit(DiscourseSiwe::SmartAccountTransferRunner.restore_sql(ENV["RESTORE_SQL"]) ? 0 : 1)
end

ok = DiscourseSiwe::SmartAccountTransferRunner.run(
  env: ENV, apply: ENV["APPLY"] == "1", verify_only: ENV["VERIFY"] == "1",
)
exit(ok ? 0 : 1)
