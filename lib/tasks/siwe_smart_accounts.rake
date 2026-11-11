# frozen_string_literal: true

# Transfer forum wallet users to the Light Accounts their wallets own.
# See README "Transferring users to smart accounts".
#
#   rake siwe:smart_accounts:transfer          dry run: plan, nothing written
#   rake 'siwe:smart_accounts:transfer[apply]' backup, write, verify
#   rake siwe:smart_accounts:verify            read-only check, exit 1 on failure
#
# Options are environment variables (the same ones the script takes):
#   MERGE_DUPLICATES=1, FULL_BACKUP_TAKEN=1, SUSPECT_AFTER=<ISO time>,
#   NO_LIGHT_ACCOUNT_LOGIN_DEPLOYED=1, KEEP_USERNAMES=1, REVIEWED_ROWS=<ids>,
#   RPC_URL=<json-rpc>, SKIP_CODE_CHECK=1, FORUM_ADDRESS_MAP=<path>.
namespace :siwe do
  namespace :smart_accounts do
    load_runner = lambda do
      lib = File.expand_path('../discourse_siwe', __dir__)
      load File.join(lib, 'eth_rpc.rb') unless defined?(DiscourseSiwe::EthRpc)
      load File.join(lib, 'light_account.rb') unless defined?(DiscourseSiwe::LightAccount)
      require File.join(lib, 'smart_account_transfer_runner.rb')
      DiscourseSiwe::SmartAccountTransferRunner
    end

    desc 'Transfer siwe users to their Light Accounts (dry run; transfer[apply] writes)'
    task :transfer, [:mode] => :environment do |_t, args|
      mode = args[:mode].to_s
      unless ['', 'dry', 'apply'].include?(mode)
        abort "Unknown mode #{mode.inspect}: use siwe:smart_accounts:transfer or siwe:smart_accounts:transfer[apply]"
      end

      ok = load_runner.call.run(env: ENV, apply: mode == 'apply')
      exit 1 unless ok
    end

    desc 'Check that every siwe user is on a Light Account or a recognised skip (read-only)'
    task verify: :environment do
      ok = load_runner.call.run(env: ENV, verify_only: true)
      exit 1 unless ok
    end
  end
end
