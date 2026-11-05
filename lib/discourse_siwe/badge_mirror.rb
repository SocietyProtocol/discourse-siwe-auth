# frozen_string_literal: true

require 'set'
require 'time'
require 'timeout'

module DiscourseSiwe
  # Needs (loaded by the caller, in this order): BadgeOwnership, GroupSyncPlanner,
  # SubgraphClient, BadgeContent, BadgeCatalog.
  #
  # Mirrors on-chain Society badges into native Discourse badges.
  #
  # Two steps, both driven by the chain:
  #   1. catalog: which badges exist and how their forum rows look
  #      (BadgeCatalog; source: the query gateway)
  #   2. holders: who holds them (source: balanceOfBatch via BadgeOwnership,
  #      NEVER the subgraph presence set)
  #
  # No Discourse and no network code lives here; collaborators are injected:
  #
  #   catalog     ->() { raw gateway rows }, raising SubgraphClient::Error; nil skips the step
  #   store       #records -> { token_id => record }   #save_record(record)
  #               #meta -> { count: n }                #save_meta(hash)
  #               #pending -> { "token" => { user_id => runs } }   #save_pending(hash)
  #               #hold? -> bool   #set_hold(bool)
  #   badges      #snapshots(records) #taken_names #grouping_id(create:)
  #               #create(attrs) -> badge_id   #update(badge_id, attrs)
  #   images      ->(url) { { upload_id:, hash: } | nil }, bounded by config.image_timeout seconds in total
  #   grants      #holders(badge_id) -> Set of user ids   #grant(badge_id, user_id, suppress:)
  #               #revoke(badge_id, user_id)
  #   users       [{ id:, username:, addresses: [..] }] eligible members with a wallet
  #   ownership   ->(addresses, token_ids) { { address => { id => Integer | nil } } },
  #               raising BadgeOwnership::SourceError when the chain is unusable
  #
  # Safety rules (all unit tested):
  #   * unknown is never zero: a nil balance never revokes
  #   * any source problem (catalog error or distrust, chain error, no
  #     readable balance) blocks EVERY revoke of the run
  #   * a member must be seen without the badge `confirmations` runs in a row
  #   * brake: per badge and across the whole run, more than max(floor,
  #     percent) revokes at once revokes nobody
  #   * a brake or a source problem raises a revoke hold (kept for the report)
  #   * a per-login run (user_ids) is ADD-ONLY: it never revokes and never
  #     reads, advances or writes the confirmation counters or the hold flag,
  #     so it cannot race the full run or bypass its brakes. Revokes are
  #     decided only by the full run (serialised by the caller)
  #   * a person with several accounts (shared addresses) is evaluated over
  #     the union of all their addresses; a duplicate's grants are only
  #     revoked when that union was read
  #   * mode 'log' reads and reports; it writes nothing
  class BadgeMirror
    MODES = %w[log enforce].freeze
    REPORT_NAMES = 25

    # Settings the orchestrator needs. allowlist: Set of token ids.
    Config = Struct.new(
      :allowlist, :confirmations, :floor, :percent, :notify, :app_url, :max_images, :image_timeout,
      keyword_init: true
    )

    def self.config(**overrides)
      Config.new(
        **{ allowlist: Set.new, confirmations: 2, floor: 5, percent: 20, notify: true, app_url: '', max_images: 25, image_timeout: 25 }.merge(overrides),
      )
    end

    # Users that share any address are one person (the Light Account rewrite
    # can leave duplicate rows). The lowest user id, the oldest account, keeps
    # the badges; the others get none. Stable across the E/S login flip
    # because it does not depend on which address is the user's wallet today.
    #
    # Each winner carries the UNION of the addresses of its whole group, so
    # the person is judged by everything they hold, not by the winner's own
    # (possibly stale or incomplete) address list.
    # => { winners: [user with merged :addresses], skipped: { loser_id => winner_id } }
    def self.dedupe(users)
      parent = {}
      find = lambda do |x|
        parent[x] = x unless parent.key?(x)
        parent[x] = find.call(parent[x]) unless parent[x] == x
        parent[x]
      end
      users.each do |user|
        user[:addresses].each { |address| parent[find.call(address)] = find.call(user[:addresses].first) }
      end

      groups = users.group_by { |u| u[:addresses].empty? ? "none-#{u[:id]}" : find.call(u[:addresses].first) }
      winners = []
      skipped = {}
      groups.each_value do |members|
        winner = members.min_by { |u| u[:id] }
        winners << winner.merge(addresses: members.flat_map { |u| u[:addresses] }.uniq)
        members.each { |u| skipped[u[:id]] = winner[:id] unless u[:id] == winner[:id] }
      end
      { winners: winners.sort_by { |u| u[:id] }, skipped: skipped }
    end

    # Per-login debounce: due when never synced or the last sync is older
    # than `interval` seconds.
    def self.login_due?(last_synced_at, now, interval: 3600)
      return true if last_synced_at.nil?

      now.to_i - last_synced_at.to_i >= interval
    end

    def initialize(store:, badges:, grants:, users:, ownership:, config:, catalog: nil, images: nil, log: ->(_m) {}, now: -> { Time.now.utc })
      @catalog = catalog
      @store = store
      @badges = badges
      @images = images
      @grants = grants
      @users = users
      @ownership = ownership
      @config = config
      @log = log
      @now = now
      @errors = []
    end

    # mode: 'log' | 'enforce'. user_ids: restrict the holder step to these
    # members (the per-login job; skips the catalog). Such a run is add-only
    # and touches no counter and no flag.
    def run(mode:, user_ids: nil)
      raise ArgumentError, "mode must be one of #{MODES.join(', ')}" unless MODES.include?(mode)

      @mode = mode
      @enforce = mode == 'enforce'
      @user_run = !user_ids.nil?
      @revoke_blocked = nil
      @report = { status: :ok, mode: mode }

      if @user_run
        @revoke_blocked = 'add-only run'
        records = @store.records
      else
        records = sync_catalog
      end

      reconcile_holders(records, user_ids)
      finish
      @report
    end

    private

    # ---- catalog ----------------------------------------------------------

    # => the mirrored records as they are (enforce) or would be (log).
    def sync_catalog
      return @store.records unless @catalog

      begin
        parsed = BadgeCatalog.parse(@catalog.call)
      rescue SubgraphClient::Error => e
        @revoke_blocked = "catalog unavailable (#{e.message})"
        @report[:catalog] = { error: e.message }
        @log.call("catalog error: #{e.message}")
        return @store.records
      end

      records = @store.records
      grouping_id = @badges.grouping_id(create: @enforce)
      plan = BadgeCatalog.plan(
        entries: parsed[:entries], records: records, snapshots: @badges.snapshots(records),
        taken: @badges.taken_names, allowlist: @config.allowlist, grouping_id: grouping_id,
        last_count: @store.meta[:count], confirmations: @config.confirmations, now: @now.call, app_url: @config.app_url,
      )
      catalog = { seen: plan[:seen], rejected: parsed[:rejected], created: [], updated: [], archived: [], unarchived: [], images: { fetched: 0, failed: 0, deferred: 0 } }
      @report[:catalog] = catalog

      if plan[:distrust]
        catalog[:distrust] = plan[:distrust]
        @revoke_blocked = "catalog not trusted (#{plan[:distrust]})"
        @log.call("catalog not trusted: #{plan[:distrust]}")
        return records
      end

      view = records.dup
      images_left = @config.max_images
      plan[:actions].each do |action|
        images_left = apply_action(action, view, catalog, images_left)
      end
      @store.save_meta(count: plan[:seen], at: @now.call.iso8601) if @enforce
      @enforce ? @store.records : view
    end

    # Applies (enforce) or just records (log) one catalog action.
    def apply_action(action, view, catalog, images_left)
      id = action[:token_id]
      record = action[:record]
      bucket = { create: :created, update: :updated, archive: :archived, unarchive: :unarchived }[action[:op]]
      if action[:op] == :skip
        @errors << "token #{id}: #{action[:error]}"
        return images_left
      end

      unless @enforce
        catalog[bucket] << id if bucket
        view[id] = record
        catalog[:images][:deferred] += 1 if action[:image_source]
        return images_left
      end

      begin
        attrs = action[:attrs]
        if action[:op] == :create
          record = record.merge(badge_id: @badges.create(attrs))
        elsif attrs.any? && record[:badge_id]
          @badges.update(record[:badge_id], attrs)
        end
        @store.save_record(record)
        catalog[bucket] << id if bucket
      rescue StandardError => e
        @errors << "token #{id}: #{e.class} #{e.message[0, 120]}"
        return images_left
      end

      return images_left unless action[:image_source]

      if images_left <= 0
        catalog[:images][:deferred] += 1
        return images_left
      end
      attach_image(record, action[:image_source], catalog)
      images_left - 1
    end

    # The whole fetch is bounded by config.image_timeout: the image host is
    # chosen by the badge's creator, and a host that trickles bytes must not
    # hold up every grant and revoke of the run. A failed source is remembered
    # (image_failed_at / image_failed_source) so it is not retried every hour.
    def attach_image(record, url, catalog)
      result = Timeout.timeout(@config.image_timeout) { @images && @images.call(url) }
      if result
        @badges.update(record[:badge_id], image_upload_id: result[:upload_id])
        @store.save_record(
          record.merge(image_source: url, image_upload_id: result[:upload_id], image_hash: result[:hash],
                       image_failed_at: nil, image_failed_source: nil),
        )
        catalog[:images][:fetched] += 1
      else
        image_failed(record, url, catalog)
      end
    rescue StandardError => e # includes Timeout::Error
      @errors << "token #{record[:token_id]}: image #{e.class}"
      image_failed(record, url, catalog)
    end

    def image_failed(record, url, catalog)
      catalog[:images][:failed] += 1
      @store.save_record(record.merge(image_failed_at: @now.call.iso8601, image_failed_source: url))
    rescue StandardError => e
      @errors << "token #{record[:token_id]}: image state #{e.class}"
    end

    # ---- holders ----------------------------------------------------------

    def reconcile_holders(records, user_ids)
      live = records.values.reject { |r| r[:archived] }.sort_by { |r| r[:token_id] }
      return @report[:badges] = {} if live.empty?

      dedupe = self.class.dedupe(@users)
      evaluated = dedupe[:winners].map { |u| u[:id] } + dedupe[:skipped].keys
      evaluated &= user_ids if user_ids
      evaluated = Set.new(evaluated)
      # Whose holdings are needed: every winner of an evaluated person. A
      # duplicate account is judged by the holdings of its whole group.
      needed = Set.new(evaluated.map { |id| dedupe[:skipped][id] || id })
      owners = dedupe[:winners].select { |u| needed.include?(u[:id]) }
      losers_of = Hash.new { |h, k| h[k] = [] }
      dedupe[:skipped].each { |loser, winner| losers_of[winner] << loser }
      @report[:duplicates_skipped] = dedupe[:skipped].select { |id, _| evaluated.include?(id) }.map { |id, winner| { skipped: label(id), kept: label(winner) } } if dedupe[:skipped].any?
      return @report[:badges] = {} if evaluated.empty?

      token_ids = live.map { |r| r[:token_id] }
      balances = fetch_balances(owners.flat_map { |u| u[:addresses] }.uniq, token_ids)
      unless balances
        @report[:status] = :source_error
        @revoke_blocked = 'chain unavailable'
        @store.set_hold(true) if @enforce && !@user_run
        return @report[:badges] = {}
      end
      holdings = classify(owners, balances, token_ids)

      # A per-login run is add-only and stateless: it neither reads nor writes
      # the counters.
      pending = @user_run ? {} : @store.pending
      next_pending = {}
      plans = {}
      live.each do |record|
        current = record[:badge_id] ? @grants.holders(record[:badge_id]) : Set.new
        current &= evaluated if user_ids
        key = record[:token_id].to_s
        desired = Set.new
        unknown = Set.new(current - evaluated) # not evaluated (ineligible, suspended, no wallet): untouched
        owners.each do |winner|
          held = holdings[winner[:id]]
          if held[:held].include?(record[:token_id])
            desired << winner[:id] if evaluated.include?(winner[:id])
          elsif held[:unknown].include?(record[:token_id])
            # Unreadable for the person: neither the winner nor any duplicate
            # of theirs may lose the badge on this reading.
            unknown << winner[:id]
            unknown.merge(losers_of[winner[:id]])
          end
        end
        plans[record[:token_id]] = [record, current, GroupSyncPlanner.plan(
          desired: desired, current: current, protected: Set.new, unknown: unknown,
          pending: pending[key] || {}, confirmations: @config.confirmations,
          floor: @config.floor, percent: @config.percent
        )]
        next_pending[key] = plans[record[:token_id]].last.next_pending
      end

      apply_plans(plans, next_pending)
    end

    def apply_plans(plans, next_pending)
      revoke_open = @revoke_blocked.nil?
      braked_any = false

      unless @user_run
        due = plans.values.sum { |(_, _, plan)| plan.remove.size }
        total = plans.values.sum { |(_, current, _)| current.size }
        limit = [@config.floor.to_i, (total * @config.percent.to_f / 100).ceil].max
        if revoke_open && due > limit
          @report[:braked_global] = true
          braked_any = true
          revoke_open = false
        end
      end

      @report[:badges] = {}
      plans.each do |token_id, (record, current, plan)|
        braked_any ||= plan.braked
        plan.remove.clear unless revoke_open
        apply_plan(record, plan) if @enforce
        @report[:badges][token_id.to_s] = describe(record, plan, revoke_open)
        mark_backfilled(record) if @enforce && !@user_run
      end

      # Only a full run writes state; a per-login run (add-only) writes grants and nothing else.
      if @enforce && !@user_run
        @store.save_pending(next_pending) if revoke_open
        @store.set_hold(braked_any || !@revoke_blocked.nil?)
      end
    end

    def apply_plan(record, plan)
      suppress = !@config.notify || !record[:backfilled]
      plan.add.each do |user_id|
        begin
          @grants.grant(record[:badge_id], user_id, suppress: suppress) || (@errors << "grant #{record[:token_id]} -> #{label(user_id)}: refused")
        rescue StandardError => e
          @errors << "grant #{record[:token_id]} -> #{label(user_id)}: #{e.class}"
        end
      end
      plan.remove.each do |user_id|
        begin
          @grants.revoke(record[:badge_id], user_id)
        rescue StandardError => e
          @errors << "revoke #{record[:token_id]} -> #{label(user_id)}: #{e.class}"
        end
      end
    end

    # The first full pass over a badge is its backfill: grants made until
    # then are silent. After it, new holders are notified.
    def mark_backfilled(record)
      return if record[:backfilled] || record[:badge_id].nil?

      @store.save_record(record.merge(backfilled: true))
    end

    def fetch_balances(addresses, token_ids)
      return {} if addresses.empty?

      balances = @ownership.call(addresses, token_ids)
      # If nothing at all could be read the source is down, whatever the
      # individual calls said.
      if balances.values.flat_map(&:values).compact.empty?
        @report[:error] = 'no balance could be read'
        return nil
      end
      balances
    rescue BadgeOwnership::SourceError => e
      @report[:error] = e.message
      nil
    end

    # => { user_id => { held: Set[token ids], unknown: Set[token ids] } }
    def classify(owners, balances, token_ids)
      owners.each_with_object({}) do |user, out|
        held = Set.new
        unknown = Set.new
        token_ids.each do |token_id|
          values = user[:addresses].map { |address| (balances[address] || {})[token_id] }
          if values.compact.any?(&:positive?)
            held << token_id
          elsif values.empty? || values.include?(nil)
            unknown << token_id
          end
        end
        out[user[:id]] = { held: held, unknown: unknown }
      end
    end

    # ---- report -----------------------------------------------------------

    def label(user_id)
      @names ||= @users.each_with_object({}) { |u, h| h[u[:id]] = u[:username] }
      @names[user_id] || "##{user_id}"
    end

    def names(ids)
      list = ids.map { |id| label(id) }
      list.size > REPORT_NAMES ? list.first(REPORT_NAMES) + ["... #{list.size - REPORT_NAMES} more"] : list
    end

    def describe(record, plan, revoke_open)
      summary = {
        name: record[:name_chain], badge_id: record[:badge_id],
        add: names(plan.add), remove: names(plan.remove), deferred: names(plan.deferred),
        braked: plan.braked, counts: { add: plan.add.size, remove: plan.remove.size, deferred: plan.deferred.size },
      }
      verb = @enforce ? 'applied' : 'would'
      @log.call(
        "badge #{record[:token_id]}: #{verb} add=#{plan.add.size} remove=#{plan.remove.size} " \
        "deferred=#{plan.deferred.size}#{' BRAKED' if plan.braked}#{' (revokes blocked)' unless revoke_open}",
      )
      summary
    end

    def finish
      @report[:revoke_blocked] = @revoke_blocked if @revoke_blocked
      @report[:errors] = @errors.first(10) if @errors.any?
      @report[:status] = :errors if @report[:status] == :ok && @errors.any?
    end
  end
end
