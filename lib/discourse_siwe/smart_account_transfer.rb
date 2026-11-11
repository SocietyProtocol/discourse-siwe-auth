# frozen_string_literal: true

require_relative 'smart_account_rewrite'

module DiscourseSiwe
  # Transfers every forum wallet user to the Light Account their wallet owns,
  # so the same wallet keeps signing in to the same Discourse user with all
  # of its posts, groups, badges and settings.
  #
  # This class holds no Discourse code. SmartAccountRewrite decides what to
  # do; the store (SmartAccountTransferRunner::Store on a forum, a fake in
  # the tests) reads and writes:
  #
  #   store.accounts -> rows for SmartAccountRewrite.plan / transfers
  #   store.suggest_username(checksummed_smart, free_username) -> username
  #   store.transaction { }
  #   store.backup(run_id, merge_user_ids:) -> [table names]
  #   store.backup_runs -> [run ids of earlier backups, oldest first]  (optional)
  #   store.delete_account(id)        store.set_uid(id, uid)
  #   store.set_info(id, { 'nickname' => .., 'name' => .. })
  #   store.set_fields(user_id, { 'wallet_address' => .., .. })
  #   store.clear_fields(user_id, [names])   store.set_name(user_id, name)
  #   store.username(user_id)         store.change_username(user_id, to)
  #   store.merge_available?          store.merge_users(loser_id, survivor_id)
  #   store.after_transfer(moved_user_ids:, merged:) -> [lines]   (optional)
  #
  # Order of an apply:
  #   1. one transaction: backup tables, then every account that is not part
  #      of a merge (provider_uid, custom fields, display name, info);
  #   2. each duplicate pair: UserMerger outside a wrapping transaction (as
  #      Discourse runs it), then one transaction for the survivor's account;
  #   3. usernames, through UsernameChanger, suggested only now so a merged
  #      survivor can take the name its duplicate held;
  #   4. a verification pass on fresh data.
  # Every step only writes what is still different, so a re-run after a
  # failure continues where it stopped and a second run writes nothing.
  class SmartAccountTransfer
    REWRITE = SmartAccountRewrite
    Refused = Class.new(StandardError)

    # Set by the transfer so a fresh Society lookup runs at the next sign-in.
    STALE_FIELDS = %w[society_resolved_at].freeze

    attr_reader :counts

    # pairs: [[eoa, smart]] from forum-address-map.json (self-test and proof
    #   of owners). code_for: ->(address) { code hex | '' | nil } or nil.
    # reviewed: ids of :review rows the operator accepts as they are.
    # no_login_deployed / suspect_after / full_backup_taken: see README.
    def initialize(store:, pairs:, code_for: nil, apply: false, merge: false, keep_usernames: false,
                   short_name: false, suspect_after: nil, no_login_deployed: false,
                   full_backup_taken: false, reviewed: [], run_id: nil, out: ->(_line) {})
      @store = store
      @pairs = pairs
      @code_for = code_for
      @apply = apply
      @merge = merge
      @keep_usernames = keep_usernames
      @short_name = short_name
      @suspect_after = suspect_after
      @no_login_deployed = no_login_deployed
      @full_backup_taken = full_backup_taken
      @reviewed = reviewed
      @run_id = run_id || Time.now.utc.strftime('%Y%m%d%H%M%S')
      @out = out
      @codes = {}
      @counts = Hash.new(0)
    end

    # => { status: :dry_run | :applied | :refused | :verification_failed,
    #      ok:, counts:, verification:, backup: [tables] }
    def run
      say "self-test: #{REWRITE.self_test!(@pairs)} address map pairs match the Light Account derivation"
      plan, transfers = read
      guard_known_light_accounts!(plan)

      print_table(plan)
      todo = transfers.select { |t| REWRITE.changes?(t) }
      print_transfers(todo)
      projected = REWRITE.verify(plan, transfers, reviewed: @reviewed)
      print_verification(projected, applied: false, transfers: transfers)

      unless @apply
        if @suspect_after.nil? && !@no_login_deployed
          say "\nNOTE: an apply needs SUSPECT_AFTER or NO_LIGHT_ACCOUNT_LOGIN_DEPLOYED=1. SUSPECT_AFTER changes " \
              'the plan (later rows with no proof of their owner become review): if you will apply with it, ' \
              'dry-run with it.'
        end
        print_plan_options
        say "\nDRY RUN: nothing written."
        return result(:dry_run, true, projected)
      end

      refuse_unsafe_apply!(todo)
      tables = []
      if todo.empty?
        say "\nNothing to write: every account is already where this plan puts it. No backup taken."
      else
        tables = apply!(todo)
        print_applied(tables)
      end

      verification = verify_now
      print_plan_options
      status = verification[:ok] ? :applied : :verification_failed
      result(status, verification[:ok], verification, tables)
    rescue Refused => e
      say "\nREFUSED, nothing written: #{e.message}"
      result(:refused, false, nil)
    end

    # Read-only: plans from the forum as it is now and fails unless every
    # siwe account is on its Light Account or a recognised skip.
    def verify
      say "self-test: #{REWRITE.self_test!(@pairs)} address map pairs match the Light Account derivation"
      verification = verify_now(table: true)
      result(verification[:ok] ? :verified : :verification_failed, verification[:ok], verification)
    end

    private

    def say(line)
      @out.call(line)
    end

    def result(status, ok, verification, tables = [])
      { status: status, ok: ok, counts: @counts.dup, verification: verification, backup: tables }
    end

    # eth_getCode once per address; a failure (nil) is asked again.
    def code_lookup
      return nil unless @code_for

      lambda do |address|
        key = address.to_s.downcase
        @codes[key] = @code_for.call(address) if @codes[key].nil?
        @codes[key]
      end
    end

    def read
      rows = @store.accounts
      plan = REWRITE.plan(rows, code_for: code_lookup, suspect_after: @suspect_after, known_pairs: @pairs)
      transfers = REWRITE.transfers(
        plan, merge: @merge, short_name: @short_name, keep_usernames: @keep_usernames,
              username_for: ->(smart, free) { @store.suggest_username(smart, free) },
      )
      [plan, transfers]
    end

    # Known Light Accounts are planned as already/adopt/recase, or as a
    # duplicate that stays on the same address; this must hold.
    def guard_known_light_accounts!(plan)
      known = {}
      @pairs.each { |_, smart| known[smart.to_s.downcase] = true }
      bad = plan.select do |p|
        %i[rewrite duplicate].include?(p[:status]) && known[p[:from].to_s.downcase] &&
          !LightAccount.same_address?(p[:from], p[:to])
      end
      raise "BUG: would rewrite known Light Accounts #{bad.map { |p| p[:from] }.join(', ')}" if bad.any?
    end

    def refuse_unsafe_apply!(todo)
      if @suspect_after.nil? && !@no_login_deployed
        raise Refused, 'an apply needs SUSPECT_AFTER (first deploy of a build with the Light Account login, ' \
                       '8a4f838 or later), or NO_LIGHT_ACCOUNT_LOGIN_DEPLOYED=1 if nobody ever signed in through one here'
      end

      merges = todo.select { |t| t[:merge] }
      return if merges.empty?
      raise Refused, 'MERGE_DUPLICATES=1 but UserMerger is not available in this Discourse' unless @store.merge_available?
      return if @full_backup_taken

      raise Refused, "#{merges.size} duplicate user(s) would be merged, which the siwe_backup tables cannot undo. " \
                     'Take a full backup (discourse backup) first, then pass FULL_BACKUP_TAKEN=1'
    end

    # ---- apply ---------------------------------------------------------------

    def apply!(todo)
      merges = todo.select { |t| t[:merge] }
      plain = todo - merges
      tables = nil
      @earlier_runs = @store.respond_to?(:backup_runs) ? Array(@store.backup_runs) - [@run_id] : []

      say "\nAPPLYING (backup run #{@run_id})"
      begin
        @store.transaction do
          merge_user_ids = merges.flat_map { |t| [t[:user_id], t[:merge][:user_id]] }
          tables = @store.backup(@run_id, merge_user_ids: merge_user_ids)
          plain.each { |t| write(t) }
        end
      rescue StandardError
        @counts.clear
        say 'FAILED in the first transaction: it was rolled back, nothing is written and no backup table is left.'
        raise
      end
      say "backup: #{tables.join(', ')}"
      print_earlier_runs

      # The store hook also runs for what was written before a failure.
      written = plain.dup
      begin
        merges.each do |t|
          merge!(t)
          written << t
        end
        todo.each { |t| rename_username(t) }
      ensure
        after_transfer(written)
      end
      tables
    end

    def merge!(transfer)
      loser = transfer[:merge]
      begin
        @store.merge_users(loser[:user_id], transfer[:user_id])
      rescue StandardError
        say "FAILED merging user #{loser[:user_id]} (#{loser[:username]}) into #{transfer[:user_id]} " \
            "(#{transfer[:username]}). Accounts listed before it are written; this pair is not. " \
            'Fix the cause and run the same command again. If the merge stopped half way, user ' \
            "#{loser[:user_id]} can be left without a wallet, where no later run or verification sees it: " \
            "if it still exists after the re-run, merge it into user #{transfer[:user_id]} from its admin page."
        raise
      end
      @counts[:merged] += 1
      say "merged user #{loser[:user_id]} (#{loser[:username]}) into #{transfer[:user_id]} (#{transfer[:username]})"
      begin
        @store.transaction { write(transfer) }
      rescue StandardError
        say "FAILED writing the account of user #{transfer[:user_id]} after its merge (rolled back). " \
            'The merge itself is done. Run the same command again: it moves the account.'
        raise
      end
    end

    # Everything of one transfer except the merge and the username.
    def write(transfer)
      if transfer[:delete]
        @store.delete_account(transfer[:delete])
        @counts[:rows_deleted] += 1
      end
      if transfer[:delete_orphan]
        @store.delete_account(transfer[:delete_orphan])
        @counts[:rows_deleted] += 1
      end
      if transfer[:uid]
        @store.set_uid(transfer[:account_id], transfer[:uid][:to])
        @counts[:uids] += 1
      end
      if transfer[:fields].any?
        values = {}
        transfer[:fields].each { |f| values[f[:field].to_s] = f[:to] }
        @store.set_fields(transfer[:user_id], values)
        @counts[:fields] += values.size
      end
      @store.clear_fields(transfer[:user_id], STALE_FIELDS) if transfer[:moved]

      info = {}
      transfer[:renames].each do |r|
        case r[:field]
        when :name
          @store.set_name(transfer[:user_id], r[:to])
          @counts[:names] += 1
        when :info_nickname then info['nickname'] = r[:to]
        when :info_name then info['name'] = r[:to]
        end
      end
      return if info.empty?

      @store.set_info(transfer[:account_id], info)
      @counts[:info] += info.size
    end

    # After every merge, so the name a merged duplicate held is free: the
    # target is suggested now, from the checksummed Light Account itself.
    def rename_username(transfer)
      rename = transfer[:renames].find { |r| r[:field] == :username }
      return unless rename

      current = @store.username(transfer[:user_id])
      unless current == rename[:from]
        @counts[:usernames_skipped] += 1
        say "username of user #{transfer[:user_id]} is now #{current}, not #{rename[:from]}: left alone"
        return
      end

      to = @store.suggest_username(transfer[:smart], current)
      if to.nil? || to == current
        @counts[:usernames_skipped] += 1
        return
      end

      @store.change_username(transfer[:user_id], to)
      @counts[:usernames] += 1
      say "renamed user #{transfer[:user_id]}: #{current} -> #{to}"
    end

    # Optional store hook for state other features keep per user. It never
    # fails the transfer: by now the accounts are written.
    def after_transfer(written)
      return unless @store.respond_to?(:after_transfer) && written.any?

      moved = written.select { |t| t[:moved] }.map { |t| t[:user_id] }
      merged = {}
      written.each { |t| merged[t[:merge][:user_id]] = t[:user_id] if t[:merge] }
      Array(@store.after_transfer(moved_user_ids: moved, merged: merged)).each { |line| say line }
    rescue StandardError => e
      say "WARNING: the store's after_transfer step failed (#{e.class}: #{e.message}). The accounts are transferred."
    end

    # ---- verification ---------------------------------------------------------

    def verify_now(table: false)
      plan, transfers = read
      print_table(plan) if table
      verification = REWRITE.verify(plan, transfers, reviewed: @reviewed, applied: true)
      print_verification(verification, applied: true, transfers: transfers)
      verification
    end

    # ---- output ---------------------------------------------------------------

    def print_table(plan)
      header = %w[status row user username from to note]
      table = plan.map do |p|
        [p[:status], p[:row][:id], p[:row][:user_id], p[:row][:username], p[:from], p[:to], p[:note]].map(&:to_s)
      end
      widths = header.each_index.map { |i| ([header[i]] + table.map { |r| r[i] }).map(&:length).max }
      ([header] + table).each { |r| say r.each_with_index.map { |c, i| c.ljust(widths[i]) }.join('  ').rstrip }
      counts = plan.group_by { |p| p[:status] }.map { |s, ps| "#{s}=#{ps.size}" }.join(' ')
      say "\n#{plan.size} siwe accounts: #{counts}"
    end

    def print_transfers(todo)
      if todo.empty?
        say "\nPLAN: nothing to write."
        return
      end

      say "\nPLAN, per user#{@keep_usernames ? ' (KEEP_USERNAMES=1: usernames are kept)' : ''}:"
      todo.each do |t|
        say "user #{t[:user_id]} (#{t[:username]}), account row #{t[:account_id]}, #{t[:status]}:"
        if t[:merge]
          say "  merge               user #{t[:merge][:user_id]} (#{t[:merge][:username]}) into this user"
        end
        if t[:delete]
          say "  delete siwe row     #{t[:delete]}#{t[:merge] ? ' (the merged user\'s account)' : ' (no user)'}"
        end
        say "  delete siwe row     #{t[:delete_orphan]} (no user)" if t[:delete_orphan]
        say "  provider_uid        #{t[:uid][:from]} -> #{t[:uid][:to]}" if t[:uid]
        (t[:fields] + t[:renames]).each do |c|
          say "  #{c[:field].to_s.ljust(19)} #{c[:from].nil? ? '(none)' : c[:from]} -> #{c[:to]}"
        end
      end
      say plan_summary(todo)
    end

    def plan_summary(todo)
      renames = todo.flat_map { |t| t[:renames] }
      count = ->(field) { renames.count { |r| r[:field] == field } }
      "#{todo.size} users change: #{todo.count { |t| t[:uid] }} provider_uid, " \
        "#{todo.sum { |t| t[:fields].size }} custom fields, #{count.call(:name)} display names, " \
        "#{count.call(:username)} usernames, #{count.call(:info_nickname) + count.call(:info_name)} info values, " \
        "#{todo.count { |t| t[:merge] }} merges, " \
        "#{todo.count { |t| t[:delete] && !t[:merge] } + todo.count { |t| t[:delete_orphan] }} orphan rows replaced"
    end

    def print_verification(verification, applied:, transfers: [])
      # Before an apply, what it will write counts as done; a merged pair is
      # one account afterwards.
      moved = verification[:done].size
      moved += verification[:pending].size - transfers.count { |t| t[:merge] } unless applied
      say "\n#{applied ? 'VERIFICATION' : 'AFTER AN APPLY'}: #{moved} on their Light Account, " \
          "#{verification[:skipped].size} recognised skips, #{verification[:accepted].size} accepted reviews, " \
          "#{verification[:unresolved].size + (applied ? verification[:pending].size : 0)} unresolved"
      (verification[:skipped] + verification[:accepted]).each { |item| say "  #{describe(item, 'skip')}" }
      verification[:unresolved].each { |item| say "  #{describe(item, 'UNRESOLVED')}" }
      if applied
        by_account = {}
        transfers.each do |t|
          by_account[t[:account_id]] = t
          by_account[t[:merge][:account_id]] = t if t[:merge]
        end
        verification[:pending].each do |item|
          left = pending_parts(by_account[item[:row][:id]])
          say "  #{describe(item.merge(reason: "still to write: #{left.join(', ')}"), 'UNRESOLVED')}"
        end
      end
      return if verification[:ok]

      say(applied ? 'VERIFICATION FAILED: the accounts marked UNRESOLVED are not transferred.' :
                    'An apply with these options would FAIL verification: see UNRESOLVED above.')
    end

    def pending_parts(transfer)
      parts = []
      parts << 'merge' if transfer[:merge]
      parts << 'delete siwe row' if (transfer[:delete] && !transfer[:merge]) || transfer[:delete_orphan]
      parts << 'provider_uid' if transfer[:uid]
      parts + (transfer[:fields] + transfer[:renames]).map { |c| c[:field].to_s }
    end

    def describe(item, label)
      row = item[:row]
      "#{label} row #{row[:id]} user #{row[:user_id] || '-'} (#{row[:username] || '-'}) #{row[:uid]} " \
        "[#{item[:status]}]: #{item[:reason]}"
    end

    def print_applied(tables)
      c = @counts
      say "\nAPPLIED: #{c[:uids]} provider_uid, #{c[:fields]} custom fields, #{c[:names]} display names, " \
          "#{c[:info]} info values and #{c[:usernames]} usernames written" \
          "#{c[:usernames_skipped].positive? ? " (#{c[:usernames_skipped]} usernames left as they were)" : ''}; " \
          "#{c[:merged]} duplicate users merged, #{c[:rows_deleted] - c[:merged]} orphan rows replaced."
      say "Backup tables: #{tables.join(', ')}. To put back what this run wrote outside merges:"
      REWRITE.restore_sql(@run_id).each_line { |line| say "  #{line.chomp}" }
      say 'This does not undo a merge and does not rename usernames back (see the README). It resets every ' \
          'siwe user to the backup, so use it right after the apply, with wallet sign-ins still off.'
      return if @earlier_runs.empty?

      say "To roll back a transfer that an earlier apply started, use the same SQL with that apply's run id " \
          "(oldest here: #{@earlier_runs.first}) in place of #{@run_id}."
    end

    # A re-run after a failure takes a new backup of a forum that is already
    # partly transferred: that one is not the way back to the start.
    def print_earlier_runs
      return if @earlier_runs.empty?

      say "Earlier backups exist: #{@earlier_runs.map { |run| "siwe_backup_#{run}_*" }.join(', ')}. If this apply " \
          'continues a transfer that an earlier apply started (a re-run after a failure), the rollback point of ' \
          "the whole transfer is the backup of that first apply (oldest here: #{@earlier_runs.first}), not " \
          "#{@run_id}: this backup already holds what the earlier apply wrote."
    end

    # Options that change the plan. A dry run, an apply and a verify only
    # agree when they get the same ones.
    def print_plan_options
      options = []
      options << "SUSPECT_AFTER=#{@suspect_after.utc.strftime('%Y-%m-%dT%H:%M:%SZ')}" if @suspect_after
      options << "REVIEWED_ROWS=#{@reviewed.join(',')}" if @reviewed.any?
      options << 'KEEP_USERNAMES=1' if @keep_usernames
      options << 'MERGE_DUPLICATES=1' if @merge
      options << 'SKIP_CODE_CHECK=1' if @code_for.nil?
      return if options.empty?

      say "\nThese options change the plan; give the same ones to every dry run, apply and verify: #{options.join(' ')}"
    end
  end
end
