# frozen_string_literal: true

module DiscourseSiwe
  # Pure planning half of the smart-account transfer (SmartAccountTransfer,
  # rake siwe:smart_accounts:transfer, script/rewrite_smart_account_users.rb):
  # decides, per siwe UserAssociatedAccount, whether its EOA uid moves to the
  # owner's Light Account, and what else of that user follows the move. No
  # ActiveRecord here so it can be unit tested standalone.
  module SmartAccountRewrite
    module_function

    # EIP-7702 delegated EOAs carry code 0xef0100 || delegate; still EOAs.
    EIP7702_PREFIX = 'ef0100'

    # Statuses that change nothing. :adopt and :recase only record the owner
    # and/or fix the case; :rewrite and :duplicate move the uid.
    # :conflict is a set of users sharing one address that the tool cannot
    # sort out by itself (see resolve_shared_addresses).
    SKIP = %i[invalid orphan already smart_of light_account contract unknown_code review conflict].freeze

    # forum-address-map.json is either { eoa => smart } or chain-keyed
    # { "1" => { eoa => smart }, "11155111" => { ... } }.
    def address_pairs(json)
      json.flat_map { |key, value| value.is_a?(Hash) ? value.to_a : [[key, value]] }
    end

    # Raises unless every pair matches our CREATE2 derivation exactly
    # (checksummed). Run before writing anything.
    def self_test!(pairs)
      raise 'self-test: address map has no pairs' if pairs.empty?

      pairs.each do |eoa, smart|
        derived = LightAccount.address(eoa)
        unless derived == LightAccount.checksum(smart) && LightAccount.same_address?(derived, smart)
          raise "self-test: #{eoa} derives #{derived}, map says #{smart}"
        end
      end
      pairs.size
    end

    # rows: [{ id:, user_id:, username:, uid:, owner:, created_at: }]
    #   owner      - siwe_owner_address custom field of the row's user, or nil
    #   created_at - row creation time (only compared to suspect_after)
    #   extra_owner (optional) - owner_address in the row's `extra` json,
    #     which the Light Account login stores at every sign-in. Only used
    #     when CREATE2 binds it to the uid, like `owner`.
    #   transfers (below) also reads wallet:, name:, info_nickname:,
    #   info_name: and user_created_at:.
    # code_for: ->(address) { code hex | '' | nil }, or nil to skip the check.
    # suspect_after: rows created after this are left for review.
    # known_pairs: [[eoa, smart]] from forum-address-map.json. A row whose uid
    #   is a known S is already moved, even with no siwe_owner_address (rows
    #   a lowercase-only rewrite left, or rows made by the Light Account
    #   login); never derive LA(S) from it.
    #
    # Returns one { row:, status:, from:, to:, other:, owner:, note: } per
    # row; owner is the EOA to store in siwe_owner_address, when missing.
    # A :duplicate made by resolve_shared_addresses also has eoa: (its from
    # is then a Light Account, not the wallet). blocker: is an orphan row
    # holding exactly the uid the entry is about to get.
    def plan(rows, code_for: nil, suspect_after: nil, known_pairs: [])
      known = { owner_of_smart: {}, eoas: {} }
      known_pairs.each do |eoa, smart|
        known[:owner_of_smart][smart.to_s.downcase] = eoa.to_s.downcase
        known[:eoas][eoa.to_s.downcase] = true
      end

      # provider_uid is unique case-sensitively, so one address can sit in
      # several rows that differ only in case: keep all of them.
      by_uid = Hash.new { |h, k| h[k] = [] }
      rows.each { |r| by_uid[r[:uid].to_s.downcase] << r }

      derived = {}
      rows.each do |r|
        derived[r[:id]] = LightAccount.address(r[:uid]) if LightAccount.valid_address?(r[:uid])
      end
      # A row with a user wins over an orphan with the same derived address.
      smart_of = {}
      rows.sort_by { |r| r[:user_id] ? 0 : 1 }.each do |r|
        s = derived[r[:id]]
        smart_of[s.downcase] ||= r if s
      end

      entries = rows.map { |r| plan_row(r, derived[r[:id]], by_uid, smart_of, code_for, suspect_after, known) }
      resolve_shared_addresses(entries, by_uid)
    end

    # Statuses that write a provider_uid (entry[:to]).
    MOVES_UID = %i[rewrite duplicate recase].freeze

    # Two rows with a user can end on one address without plan_row seeing it:
    # the same Light Account stored in two cases (the first rewrite wrote S
    # lowercase and the login of that build then made a second, checksummed
    # row), or the same wallet in two cases. Writing both would hit the
    # unique index and roll the whole run back. Such a pair becomes a
    # :duplicate (merged with MERGE_DUPLICATES=1, unresolved without); three
    # or more users, or a pair with no proven owner, become :conflict.
    #
    # Also marks an orphan row that holds exactly the uid an entry is about
    # to get (blocker:), so it is deleted first.
    def resolve_shared_addresses(entries, by_uid)
      final = ->(e) { (MOVES_UID.include?(e[:status]) ? e[:to] : e[:from]).to_s.downcase }
      groups = Hash.new { |h, k| h[k] = [] }
      entries.each do |e|
        next if e[:status] == :invalid || e[:row][:user_id].nil?

        groups[final.call(e)] << e
      end

      groups.each do |address, group|
        next if group.size < 2
        next if group.size == 2 && linked_duplicate?(group[0], group[1])

        checksummed = LightAccount.checksum(address)
        moves = group.map { |e| address_move(e, merge: true) }
        if group.size == 2 && moves.all?
          # The row that already has the final uid, if any, keeps its plan.
          keep = group.find { |e| e[:from] == checksummed } || group.max_by { |e| e[:row][:id] }
          dup = group.find { |e| !e.equal?(keep) }
          dup.merge!(
            status: :duplicate, to: checksummed, other: keep[:row], eoa: moves[0][0].to_s.downcase,
            note: "#{checksummed} is also the account of user #{keep[:row][:user_id]} " \
                  "(#{keep[:row][:username]}, row #{keep[:row][:id]})",
          )
        else
          others = ->(e) { group.reject { |o| o.equal?(e) }.map { |o| "#{o[:row][:user_id]} (row #{o[:row][:id]})" } }
          group.each do |e|
            e.merge!(
              status: :conflict, to: nil, other: nil,
              note: "shares #{checksummed} with user #{others.call(e).join(', ')}",
            )
          end
        end
      end

      entries.each do |e|
        next unless MOVES_UID.include?(e[:status]) && e[:to]

        blocker = by_uid[e[:to].downcase].find { |r| r[:user_id].nil? && r[:uid] == e[:to] && r[:id] != e[:row][:id] }
        e[:blocker] = blocker if blocker
      end
      entries
    end

    # A :duplicate and the row it names.
    def linked_duplicate?(a, b)
      [[a, b], [b, a]].any? { |d, o| d[:status] == :duplicate && d[:other] && d[:other][:id] == o[:row][:id] }
    end

    def plan_row(row, smart, by_uid, smart_of, code_for, suspect_after, known = { owner_of_smart: {}, eoas: {} })
      uid = row[:uid].to_s
      entry = { row: row, from: uid, to: nil, other: nil, owner: nil, note: nil }

      return entry.merge(status: :invalid, note: 'uid is not an address') unless smart
      return entry.merge(status: :orphan, note: 'no user') unless row[:user_id]

      owner = row[:owner]
      recorded = owner_of?(owner, uid)
      eoa_row = smart_of[uid.downcase]
      eoa_row = nil if eoa_row && eoa_row[:id] == row[:id]

      # Proof of the owner when the custom field does not hold it: the row's
      # own sign-in record, the address map, or an orphan row (no user) whose
      # uid derives this one. CREATE2 makes each of them exact.
      proven =
        if recorded
          nil
        elsif owner_of?(row[:extra_owner], uid)
          [row[:extra_owner].downcase, 'from its sign-in record']
        elsif known[:owner_of_smart][uid.downcase]
          [known[:owner_of_smart][uid.downcase], 'from the address map']
        elsif eoa_row && eoa_row[:user_id].nil?
          [eoa_row[:uid].to_s.downcase, "from orphan row #{eoa_row[:id]}"]
        end

      if recorded || proven
        checksummed = LightAccount.checksum(uid)
        set_owner = proven && proven[0]
        note = recorded ? "owner #{owner}" : "owner #{proven[0]} #{proven[1]}"
        if checksummed == uid
          return entry.merge(status: set_owner ? :adopt : :already, owner: set_owner, note: note)
        end

        return entry.merge(status: :recase, to: checksummed, owner: set_owner, note: note)
      end

      if eoa_row
        return entry.merge(
          status: :smart_of, other: eoa_row,
          note: "Light Account of #{eoa_row[:uid]} (row #{eoa_row[:id]})",
        )
      end

      # The strategy's uid has always been the SIWE message address, which is
      # EIP-55 checksummed. Another case means a script or a hand edit wrote
      # it (the first rewrite stored S lowercase), so it may already be a
      # Light Account: leave it unless it is a known wallet.
      if uid != LightAccount.checksum(uid) && !known[:eoas][uid.downcase]
        return entry.merge(
          status: :review,
          note: 'uid not checksummed and not in the address map; may already be a Light Account',
        )
      end

      if code_for
        code = code_for.call(uid)
        return entry.merge(status: :unknown_code, note: 'eth_getCode failed') if code.nil?

        code = code.downcase
        if code == LightAccount.proxy_runtime_code
          return entry.merge(status: :light_account, note: 'deployed Light Account, owner unknown')
        end
        if !code.empty? && !code.start_with?(EIP7702_PREFIX)
          return entry.merge(status: :contract, note: 'contract wallet, not an EOA')
        end
      end

      if suspect_after && row[:created_at] && row[:created_at] > suspect_after
        return entry.merge(status: :review, to: smart, note: "created after #{suspect_after}")
      end

      holders = by_uid[smart.downcase].reject { |r| r[:id] == row[:id] }
      existing = holders.find { |r| r[:user_id] }
      if existing
        return entry.merge(
          status: :duplicate, to: smart, other: existing,
          note: "#{smart} already used by user #{existing[:user_id]} (#{existing[:username]})",
        )
      end

      # A row for S with no user (UserMerger leaves one when both users had
      # a siwe row) only blocks the unique index: it is replaced.
      orphan = holders.find { |r| r[:uid] == smart } || holders.first
      if orphan
        return entry.merge(
          status: :rewrite, to: smart, other: orphan,
          note: "replaces orphan row #{orphan[:id]} (no user) holding #{smart}",
        )
      end

      entry.merge(status: :rewrite, to: smart)
    end

    # True when `owner` is an address whose Light Account is `uid`.
    def owner_of?(owner, uid)
      LightAccount.valid_address?(owner) && LightAccount.same_address?(LightAccount.address(owner), uid)
    end

    # Same shortening DisplayNameApplier uses for the 'wallet' identity.
    def short_wallet(wallet)
      w = wallet.to_s.downcase
      "#{w[0..5]}…#{w[-4..-1]}"
    end

    # A username Discourse cut from an address: 0x plus at least 8 hex digits.
    ADDRESS_USERNAME_RE = /\A0x[0-9a-fA-F]{8,40}\z/.freeze

    # [eoa, smart] of the user a plan entry leaves on a Light Account, or nil
    # when the entry moves nothing or the owner is unknown. Covers rows moved
    # by an earlier run (:already, :adopt, :recase), so a re-run still fixes
    # the names an older version of the script left behind.
    def address_move(entry, merge: false)
      case entry[:status]
      when :rewrite
        [entry[:from], entry[:to]]
      when :duplicate
        merge ? [entry[:eoa] || entry[:from], entry[:to]] : nil
      when :already, :adopt, :recase
        owner = entry[:owner] || entry[:row][:owner]
        LightAccount.valid_address?(owner) ? [owner, LightAccount.checksum(entry[:from])] : nil
      end
    end

    # The fields the login derived from the old address, and what a fresh
    # Light Account login would have put there instead.
    #
    # fields: { name:, username:, info_nickname:, info_name: } as they are now
    #   name          - users.name. New users get the full SIWE address from
    #                   the strategy; DisplayNameApplier then shortens it when
    #                   Society resolution is on.
    #   username      - users.username. Discourse cuts it from the address
    #                   (the strategy's nickname) at max_username_length.
    #   info_nickname, info_name - the associated account's info json.
    # short_name: true when a fresh login gets the short form as its name
    #   (siwe_society_enabled); a full-address name then becomes short.
    # username_for: ->(checksummed_smart) { username }, e.g.
    #   UserNameSuggester.suggest; default cuts S to the old length.
    #
    # Only a value recognisably made from eoa is replaced: the full address in
    # any case, its short form, or a username that is a prefix of it. A chosen
    # name, a Society name or an ENS name never matches. Returns
    # [{ field:, from:, to: }], empty once everything is renamed.
    def derived_renames(fields, eoa, smart, short_name: false, username_for: nil)
      return [] unless LightAccount.valid_address?(eoa) && LightAccount.valid_address?(smart)
      return [] if LightAccount.same_address?(eoa, smart)

      full = LightAccount.checksum(smart)
      out = []

      name = fields[:name].to_s.strip
      if LightAccount.same_address?(name, eoa)
        out << { field: :name, from: fields[:name], to: short_name ? short_wallet(smart) : full }
      elsif name == short_wallet(eoa)
        out << { field: :name, from: fields[:name], to: short_wallet(smart) }
      end

      username = fields[:username].to_s
      if username.match?(ADDRESS_USERNAME_RE) && eoa.downcase.start_with?(username.downcase)
        to = username_for ? username_for.call(full) : full[0, username.length]
        out << { field: :username, from: username, to: to } if to && to != username
      end

      %i[info_nickname info_name].each do |field|
        out << { field: field, from: fields[field], to: full } if LightAccount.same_address?(fields[field].to_s.strip, eoa)
      end

      out
    end

    # ---- transfer: everything that follows a user to the Light Account -----

    # The two users of a :duplicate entry (one signed in as E, the other as
    # its Light Account S). The older user survives, by user creation time
    # then user id; the other one is merged into it.
    def merge_pair(entry)
      survivor, loser = [entry[:row], entry[:other]].sort_by do |r|
        [r[:user_created_at] ? 0 : 1, r[:user_created_at].to_f, r[:user_id].to_i]
      end
      { survivor: survivor, loser: loser }
    end

    # Custom fields of a user that ends on `smart`, owned by `eoa`, as the
    # Light Account login writes them (both lowercase).
    # row: { wallet:, owner: } as stored now. Returns [{ field:, from:, to: }].
    def field_changes(row, eoa, smart)
      out = []
      wallet = smart.downcase
      owner = eoa.downcase
      out << { field: :wallet_address, from: row[:wallet], to: wallet } unless row[:wallet] == wallet
      out << { field: :siwe_owner_address, from: row[:owner], to: owner } unless row[:owner] == owner
      out
    end

    # One transfer per siwe account that ends on a Light Account, keyed by
    # that account (never by plan row), so a merged pair is one transfer on
    # the surviving account:
    #
    #   { account_id:, user_id:, username:, status:, eoa:, smart:,
    #     uid:     { from:, to: } | nil    provider_uid to write
    #     delete:  account id | nil        siwe row to delete first (the merged
    #                                      user's row, or an orphan row on S)
    #     delete_orphan: account id | nil  an orphan row on S that blocks the
    #                                      uid of a merged pair as well
    #     merge:   { user_id:, username:, account_id: } | nil   user merged in
    #     moved:   true when the account changes address in this run
    #     fields:  [{ field:, from:, to: }]   custom fields
    #     renames: [{ field:, from:, to: }]   see derived_renames }
    #
    # merge: plan :duplicate entries as merges (MERGE_DUPLICATES=1).
    # username_for: ->(checksummed_smart, free_username) { username }. With a
    #   merge, free_username is the merged user's name, which the survivor can
    #   take once that user is gone; otherwise it is the user's own.
    # A transfer with nothing to write (see changes?) is an account that is
    # already fully moved.
    def transfers(plan, merge: false, short_name: false, keep_usernames: false, username_for: nil)
      pairs = {}
      claimed = {}
      if merge
        plan.each do |p|
          next unless p[:status] == :duplicate

          pair = merge_pair(p)
          pairs[p[:row][:id]] = pair
          claimed[pair[:survivor][:id]] = true
          claimed[pair[:loser][:id]] = true
        end
      end

      plan.each_with_object([]) do |p, out|
        row = p[:row]
        pair = pairs[row[:id]]
        next if claimed[row[:id]] && !pair # the other row of a merged pair

        move = address_move(p, merge: merge)
        next unless move

        eoa = move[0].downcase
        smart = LightAccount.checksum(move[1])
        target = pair ? pair[:survivor] : row
        transfer = {
          account_id: target[:id], user_id: target[:user_id], username: target[:username],
          status: p[:status], eoa: eoa, smart: smart, uid: nil, delete: nil, merge: nil,
          delete_orphan: nil, moved: %i[rewrite duplicate].include?(p[:status]),
        }
        transfer[:uid] = { from: target[:uid], to: smart } unless target[:uid] == smart
        blocker = transfer[:uid] && p[:blocker] && p[:blocker][:id]
        if pair
          loser = pair[:loser]
          transfer[:merge] = { user_id: loser[:user_id], username: loser[:username], account_id: loser[:id] }
          transfer[:delete] = loser[:id]
          transfer[:delete_orphan] = blocker if blocker
        elsif p[:status] == :rewrite && p[:other]
          transfer[:delete] = p[:other][:id]
          transfer[:delete_orphan] = blocker if blocker && blocker != p[:other][:id]
        elsif blocker
          transfer[:delete] = blocker
        end
        transfer[:fields] = field_changes(target, eoa, smart)

        free = pair ? pair[:loser][:username] : target[:username]
        renames = derived_renames(
          { name: target[:name], username: target[:username],
            info_nickname: target[:info_nickname], info_name: target[:info_name] },
          eoa, smart, short_name: short_name,
          username_for: username_for && ->(full) { username_for.call(full, free) },
        )
        renames.reject! { |r| r[:field] == :username } if keep_usernames
        transfer[:renames] = renames
        out << transfer
      end
    end

    def changes?(transfer)
      !!(transfer[:uid] || transfer[:delete] || transfer[:delete_orphan] || transfer[:merge]) ||
        transfer[:fields].any? || transfer[:renames].any?
    end

    # Rows the transfer leaves as they are, on purpose.
    RECOGNISED_SKIPS = {
      contract: 'contract wallet, signs in as itself',
      invalid: 'uid is not an address',
      orphan: 'row has no user',
      light_account: 'deployed Light Account; its owner is recorded at the next sign-in',
    }.freeze

    # Sorts every siwe account of a plan into:
    #   done       on its Light Account, nothing left to write
    #   pending    a transfer still has something to write
    #   skipped    RECOGNISED_SKIPS
    #   accepted   :review rows the operator listed in `reviewed` (row ids)
    #   unresolved still on an old wallet and not transferred by this plan
    # Each item is { row:, status:, reason: }.
    #
    # applied: false judges a plan before it is written (pending is fine);
    # true judges the forum after an apply, where pending is a failure too.
    # => { done:, pending:, skipped:, accepted:, unresolved:, ok: }
    def verify(plan, transfers, reviewed: [], applied: false)
      by_account = {}
      transfers.each do |t|
        by_account[t[:account_id]] = t
        by_account[t[:merge][:account_id]] = t if t[:merge]
      end

      out = { done: [], pending: [], skipped: [], accepted: [], unresolved: [] }
      plan.each do |p|
        row = p[:row]
        item = { row: row, status: p[:status], reason: p[:note] }
        transfer = by_account[row[:id]]
        if RECOGNISED_SKIPS.key?(p[:status])
          out[:skipped] << item.merge(reason: RECOGNISED_SKIPS[p[:status]])
        elsif transfer
          out[changes?(transfer) ? :pending : :done] << item
        elsif p[:status] == :review && reviewed.include?(row[:id])
          out[:accepted] << item
        else
          out[:unresolved] << item.merge(reason: unresolved_reason(p))
        end
      end
      out[:ok] = out[:unresolved].empty? && !(applied && out[:pending].any?)
      out
    end

    def unresolved_reason(entry)
      other = entry[:other]
      case entry[:status]
      when :duplicate
        "user #{other[:user_id]} (#{other[:username]}) already signed in as #{entry[:to]}; " \
          'merge the two with MERGE_DUPLICATES=1'
      when :conflict
        "#{entry[:note]}; merge these users in the admin UI until at most two are left, then run again"
      when :smart_of
        "Light Account of user #{other[:user_id]} (#{other[:username]}), a duplicate that is not merged"
      when :review
        "#{entry[:note]}; check it, then list its row id in REVIEWED_ROWS"
      when :unknown_code
        'eth_getCode failed; re-run with a working RPC_URL'
      else
        entry[:note] || 'owner unknown'
      end
    end

    # ---- backup -------------------------------------------------------------

    RUN_ID_RE = /\A[0-9a-z_]{1,24}\z/.freeze

    # Custom fields the transfer itself writes or deletes.
    TRANSFER_FIELDS = %w[wallet_address siwe_owner_address society_resolved_at].freeze

    SIWE_USER_IDS_SQL =
      "SELECT user_id FROM user_associated_accounts WHERE provider_name = 'siwe' AND user_id IS NOT NULL"

    # [[table, select]] copied with CREATE TABLE ... AS before anything is
    # written. accounts, fields and users are what restore_sql reads. The
    # group_users and user_badges copies of merged users are a record of who
    # had what before the merge; nothing restores from them.
    def backup_tables(run, merge_user_ids: [])
      raise ArgumentError, "invalid backup run id: #{run.inspect}" unless run.to_s.match?(RUN_ID_RE)

      prefix = "siwe_backup_#{run}"
      tables = [
        ["#{prefix}_accounts", "SELECT * FROM user_associated_accounts WHERE provider_name = 'siwe'"],
        ["#{prefix}_fields", "SELECT * FROM user_custom_fields WHERE user_id IN (#{SIWE_USER_IDS_SQL})"],
        ["#{prefix}_users", "SELECT id, username, name, created_at FROM users WHERE id IN (#{SIWE_USER_IDS_SQL})"],
      ]
      ids = merge_user_ids.map { |id| Integer(id) }.uniq.sort
      if ids.any?
        tables << ["#{prefix}_group_users", "SELECT * FROM group_users WHERE user_id IN (#{ids.join(', ')})"]
        tables << ["#{prefix}_user_badges", "SELECT * FROM user_badges WHERE user_id IN (#{ids.join(', ')})"]
      end
      tables
    end

    BACKUP_PARTS = %w[accounts fields users].freeze

    # Run ids, oldest first, of the complete backups (the three tables
    # restore_sql reads) among `table_names`. Run ids are UTC start times,
    # so they sort by age.
    def backup_runs(table_names)
      parts = Hash.new { |h, k| h[k] = [] }
      table_names.each do |name|
        m = /\Asiwe_backup_([0-9a-z_]+?)_(accounts|fields|users)\z/.match(name.to_s)
        parts[m[1]] << m[2] if m && m[1].match?(RUN_ID_RE)
      end
      parts.select { |_, have| (BACKUP_PARTS - have).empty? }.keys.sort
    end

    # SQL that puts back what the transfer wrote outside merges: provider_uid
    # and info of every siwe row that still exists, the three custom fields,
    # and display names. It does not undo a merge, does not bring back a
    # deleted row, and does not rename usernames back.
    def restore_sql(run)
      raise ArgumentError, "invalid backup run id: #{run.inspect}" unless run.to_s.match?(RUN_ID_RE)

      prefix = "siwe_backup_#{run}"
      names = TRANSFER_FIELDS.map { |n| "'#{n}'" }.join(', ')
      <<~SQL
        BEGIN;
        UPDATE user_associated_accounts a SET provider_uid = b.provider_uid, info = b.info
          FROM #{prefix}_accounts b WHERE a.id = b.id;
        DELETE FROM user_custom_fields f USING #{prefix}_users u
          WHERE f.user_id = u.id AND f.name IN (#{names});
        INSERT INTO user_custom_fields (user_id, name, value, created_at, updated_at)
          SELECT b.user_id, b.name, b.value, b.created_at, b.updated_at
          FROM #{prefix}_fields b JOIN users u ON u.id = b.user_id
          WHERE b.name IN (#{names});
        UPDATE users u SET name = b.name FROM #{prefix}_users b WHERE u.id = b.id;
        COMMIT;
      SQL
    end
  end
end
