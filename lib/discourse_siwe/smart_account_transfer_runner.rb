# frozen_string_literal: true

require 'json'
require 'time'
require_relative 'smart_account_rewrite'
require_relative 'smart_account_transfer'

module DiscourseSiwe
  # Wires SmartAccountTransfer to real Discourse. Every decision lives in
  # SmartAccountRewrite and SmartAccountTransfer; this file only adapts.
  # Entry points: rake siwe:smart_accounts:transfer / :verify and
  # script/rewrite_smart_account_users.rb.
  #
  # Discourse APIs used (checked against the 2026.8.0 sources):
  #   UserMerger.new(source, target, acting_user).merge!   leaves the merged
  #     user's siwe row with user_id NULL when the target has one of its own
  #     (merge_user_associated_accounts), so the transfer deletes that row
  #   UserNameSuggester.suggest(name, current_username:)
  #   UsernameChanger.change(user, new_username, actor)    rewrites mentions
  #     and quotes in a background job
  module SmartAccountTransferRunner
    PROVIDER = 'siwe'
    DEFAULT_MAP = File.expand_path('../../script/forum-address-map.json', __dir__)

    module_function

    # env: the options (README "Transferring users to smart accounts"). APPLY
    # is read by the script only; the rake task passes apply:.
    # store / short_name: replaced in the unit tests; on a forum they are the
    # Discourse store and the siwe_society_enabled setting.
    # Returns true when the run (or the verification) succeeded.
    def run(env: ENV, apply: false, verify_only: false, out: ->(line) { puts line }, store: nil, short_name: nil)
      transfer = build(env, apply, out, store, short_name)
      (verify_only ? transfer.verify : transfer.run)[:ok]
    end

    def build(env, apply, out, store, short_name)
      map_path = env['FORUM_ADDRESS_MAP'].to_s.strip.empty? ? DEFAULT_MAP : env['FORUM_ADDRESS_MAP']
      pairs = SmartAccountRewrite.address_pairs(JSON.parse(File.read(map_path)))
      out.call("address map: #{map_path}")

      suspect_after = env['SUSPECT_AFTER'].to_s.strip
      SmartAccountTransfer.new(
        store: store || Store.new,
        pairs: pairs,
        code_for: code_for(env, out),
        apply: apply,
        merge: env['MERGE_DUPLICATES'] == '1',
        keep_usernames: env['KEEP_USERNAMES'] == '1',
        short_name: short_name.nil? ? SiteSetting.siwe_society_enabled : short_name,
        suspect_after: suspect_after.empty? ? nil : parse_time(suspect_after),
        no_login_deployed: env['NO_LIGHT_ACCOUNT_LOGIN_DEPLOYED'] == '1',
        full_backup_taken: env['FULL_BACKUP_TAKEN'] == '1',
        reviewed: env['REVIEWED_ROWS'].to_s.split(',').map(&:strip).reject(&:empty?).map { |id| Integer(id) },
        out: out,
      )
    end

    # A time with no zone is UTC, never the server's local time.
    ZONED_TIME_RE = /(z|utc|gmt)\s*\z|\d:\d\d(:\d\d(\.\d+)?)?\s*[+-]\d\d(:?\d\d)?\s*\z/i.freeze

    def parse_time(text)
      return Time.parse(text).utc if text.match?(ZONED_TIME_RE)

      # Time.parse ignores a zone that follows a bare date.
      Time.parse("#{text}#{text.match?(/\d:\d\d/) ? '' : ' 00:00'} UTC").utc
    end

    # The RPC URL carries an API key: it is never printed.
    def code_for(env, out)
      if env['SKIP_CODE_CHECK'] == '1'
        out.call('WARNING: SKIP_CODE_CHECK=1, contract wallets are not detected and would be rewritten')
        return nil
      end

      url = env['RPC_URL'].to_s.strip
      url = EthRpc.rpc_url.to_s if url.empty?
      raise 'No RPC: set RPC_URL (or siwe_ethereum_rpc_url), or SKIP_CODE_CHECK=1' if url.empty?

      ->(address) { EthRpc.get_code(address, url: url) }
    end

    # Reads and writes for SmartAccountTransfer.
    class Store
      def accounts
        accounts = UserAssociatedAccount.where(provider_name: PROVIDER).includes(:user).order(:id).to_a
        fields = Hash.new { |h, k| h[k] = {} }
        UserCustomField
          .where(user_id: accounts.map(&:user_id).compact, name: %w[wallet_address siwe_owner_address])
          .order(:id)
          .pluck(:user_id, :name, :value)
          .each { |user_id, name, value| fields[user_id][name] = value }

        accounts.map do |account|
          user = account.user
          info = account.info.is_a?(Hash) ? account.info : {}
          extra = account.extra.is_a?(Hash) ? account.extra : {}
          {
            id: account.id,
            user_id: user&.id,
            username: user&.username,
            name: user&.name,
            uid: account.provider_uid,
            owner: user && fields[user.id]['siwe_owner_address'],
            wallet: user && fields[user.id]['wallet_address'],
            extra_owner: extra['owner_address'],
            info_nickname: info['nickname'],
            info_name: info['name'],
            created_at: account.created_at,
            user_created_at: user&.created_at,
          }
        end
      end

      def suggest_username(smart, free_username)
        UserNameSuggester.suggest(smart, current_username: free_username)
      end

      def transaction
        ActiveRecord::Base.transaction { yield }
      end

      # CREATE TABLE ... AS on the ActiveRecord connection, so the copies are
      # part of the surrounding transaction.
      def backup(run, merge_user_ids:)
        tables = SmartAccountRewrite.backup_tables(run, merge_user_ids: merge_user_ids)
        tables.each { |name, select| ActiveRecord::Base.connection.execute("CREATE TABLE #{name} AS #{select}") }
        tables.map(&:first)
      end

      # Run ids of the complete siwe_backup_* sets already in the database.
      def backup_runs
        names = ActiveRecord::Base.connection.select_values(
          "SELECT tablename FROM pg_tables WHERE schemaname = ANY (current_schemas(false)) " \
          "AND tablename LIKE 'siwe!_backup!_%' ESCAPE '!'",
        )
        SmartAccountRewrite.backup_runs(names)
      end

      # Only a row nobody signs in to any more: no user, or a user that is
      # gone. A row that still belongs to a user is never deleted.
      def delete_account(id)
        row = UserAssociatedAccount.find_by(provider_name: PROVIDER, id: id)
        return unless row

        if row.user_id && User.exists?(id: row.user_id)
          raise "siwe row #{id} still belongs to user #{row.user_id}; not deleted"
        end

        row.delete
      end

      def set_uid(id, uid)
        UserAssociatedAccount.find(id).update!(provider_uid: uid)
      end

      def set_info(id, values)
        account = UserAssociatedAccount.find(id)
        account.update!(info: (account.info.is_a?(Hash) ? account.info : {}).merge(values))
      end

      def set_fields(user_id, values)
        user = User.find(user_id)
        values.each { |name, value| user.custom_fields[name] = value }
        user.save_custom_fields(true)
      end

      def clear_fields(user_id, names)
        UserCustomField.where(user_id: user_id, name: names).delete_all
      end

      def set_name(user_id, name)
        User.find(user_id).update!(name: name)
      end

      def username(user_id)
        User.where(id: user_id).pluck(:username).first
      end

      def change_username(user_id, to)
        user = User.find(user_id)
        return if UsernameChanger.change(user, to, Discourse.system_user)

        raise "username change failed for user #{user.id} (#{user.username} -> #{to}): " \
              "#{user.errors.full_messages.join(', ')}. Everything else is written; run the same command again."
      end

      def merge_available?
        !!defined?(::UserMerger)
      end

      def merge_users(loser_id, survivor_id)
        UserMerger.new(User.find(loser_id), User.find(survivor_id), Discourse.system_user).merge!
      end
    end
  end
end
