# frozen_string_literal: true

require 'set'
require 'time'

module DiscourseSiwe
  # Needs SubgraphClient and BadgeContent loaded first.
  #
  # Which on-chain badges exist and what their forum rows should look like.
  # Pure: no Discourse, no network (the gateway client is passed to .fetch).
  #
  # Rules:
  #   * scope: official badges, plus community badges whose token id is in the
  #     allowlist. Profile badges are never fetched.
  #   * null metadata is "unknown": it never clears a description or image.
  #   * nothing is ever deleted: a badge that left the catalog (or the scope)
  #     is archived (enabled = false) after `confirmations` runs in a row.
  #   * a catalog that is empty or far smaller than the last one, or one that
  #     would archive most of what we mirror, is not trusted: no changes at all.
  module BadgeCatalog
    # The registered `Badges` document, copied from web3-app-subgraph
    # infra/query-gateway/generated/registry.js. The gateway compares the
    # printed text exactly, so change it only together with the registry.
    OPERATION = 'Badges'
    DOCUMENT = <<~GRAPHQL
      query Badges($first: Int!, $skip: Int!, $orderBy: Badge_orderBy!, $orderDirection: OrderDirection!, $where: Badge_filter) {
        badges(
          first: $first
          skip: $skip
          orderBy: $orderBy
          orderDirection: $orderDirection
          where: $where
        ) {
          id
          name
          description
          isOfficial
          isCommunity
          uri
          imageUrl
          metadata {
            description
            imageUrl
          }
          creatorAddress
          profileUser {
            name
            metadata {
              name
            }
          }
          community {
            id
            name
          }
          createdBy {
            id
            name
            bio
            imageUrl
            metadata {
              name
              bio
              imageUrl
            }
          }
        }
      }
    GRAPHQL

    PAGE_SIZE = 1000 # the operation allows up to 1000
    MAX_PAGES = 5

    # Badge appearance. Official role badges are Gold so they lead on the
    # user card; community badges are Silver. Change here to taste.
    TYPE_OFFICIAL = 1  # BadgeType::Gold
    TYPE_COMMUNITY = 2 # BadgeType::Silver
    GROUPING_NAME = 'Society Protocol'
    SEEN_REFRESH_SECONDS = 24 * 3600

    Entry = Struct.new(:token_id, :name, :official, :community, :uri, :description, :image_source, keyword_init: true)

    module_function

    def variables(first, skip)
      { first: first, skip: skip, orderBy: 'id', orderDirection: 'asc', where: { isProfile: false } }
    end

    # Raw rows from the gateway. Raises SubgraphClient::Error on any failure.
    def fetch(client)
      client.paginate(
        operation: OPERATION, document: DOCUMENT, page_size: PAGE_SIZE, max_pages: MAX_PAGES,
        variables_for: ->(first, skip) { variables(first, skip) },
        extract: ->(data) { data['badges'] },
      )
    end

    # Rows -> { entries: [Entry] sorted by id, rejected: n }.
    # Description and image are nil when unknown (null metadata, blank values).
    def parse(rows)
      seen = Set.new
      rejected = 0
      entries = []
      rows.each do |row|
        id = row.is_a?(Hash) ? BadgeContent.token_id(row['id']) : nil
        if id.nil? || seen.include?(id)
          rejected += 1
          next
        end
        seen << id
        meta = row['metadata'].is_a?(Hash) ? row['metadata'] : {}
        description = BadgeContent.plain_text(meta['description'], BadgeContent::DESCRIPTION_MAX)
        entries << Entry.new(
          token_id: id,
          name: row['name'].to_s,
          official: row['isOfficial'] == true,
          community: row['isCommunity'] == true,
          uri: row['uri'].to_s[0, BadgeContent::URL_MAX],
          description: description.empty? ? nil : description,
          image_source: BadgeContent.image_url(meta['imageUrl']),
        )
      end
      { entries: entries.sort_by(&:token_id), rejected: rejected }
    end

    def in_scope?(entry, allowlist)
      entry.official || (entry.community && allowlist.include?(entry.token_id))
    end

    # Is the catalog fit to act on? => nil, or a reason string.
    def distrust(entry_count, last_count)
      return 'catalog is empty' if entry_count.zero? && last_count.to_i.positive?
      return "catalog shrank from #{last_count} to #{entry_count}" if last_count.to_i >= 4 && entry_count * 2 < last_count

      nil
    end

    # What to write.
    #   entries      parsed catalog (all non-profile badges)
    #   records      { token_id => record } what we mirror already
    #   snapshots    { token_id => { name:, description:, long_description:, enabled:,
    #                  badge_type_id:, badge_grouping_id:, image_upload_id: } | nil }
    #                for every record (nil: the Badge row is gone)
    #   taken        Set of BadgeContent.name_key for every badge on the forum
    #   grouping_id  id of the "Society Protocol" grouping (nil in log mode
    #                when it does not exist yet)
    #
    # => { actions: [...], distrust: reason|nil, seen: n }
    #    action: { token_id:, op: :create|:update|:archive|:unarchive|:absent|:seen,
    #              attrs: {badge columns to write}, image_source: url|nil,
    #              record: {the record to store (image fields are filled by the applier)} }
    def plan(entries:, records:, snapshots:, taken:, allowlist:, grouping_id:, last_count:, confirmations:, now:, app_url: '')
      reason = distrust(entries.size, last_count)
      wanted = entries.select { |e| in_scope?(e, allowlist) }
      wanted_ids = Set.new(wanted.map(&:token_id))

      live_records = records.values.reject { |r| r[:archived] }
      would_archive = live_records.reject { |r| wanted_ids.include?(r[:token_id]) }
      if reason.nil? && would_archive.size >= 3 && would_archive.size * 2 > live_records.size
        reason = "#{would_archive.size} of #{live_records.size} mirrored badges would be archived at once"
      end
      return { actions: [], distrust: reason, seen: entries.size } if reason

      taken = taken.dup
      actions = []

      wanted.each do |entry|
        record = records[entry.token_id]
        snapshot = record && snapshots[entry.token_id]
        action = if record.nil? || snapshot.nil?
          plan_create(entry, record, taken, grouping_id, app_url, now)
        else
          plan_existing(entry, record, snapshot, taken, grouping_id, app_url, now)
        end
        actions << action if action
      end

      # Left the catalog or the scope: archive after `confirmations` runs in a
      # row. Archived records are left alone until they come back.
      records.each_value do |record|
        next if wanted_ids.include?(record[:token_id]) || record[:archived]

        misses = record[:absent_runs].to_i + 1
        archive = misses >= confirmations
        actions << {
          token_id: record[:token_id], op: archive ? :archive : :absent,
          attrs: archive ? { enabled: false } : {}, image_source: nil,
          record: record.merge(archived: archive, absent_runs: misses)
        }
      end

      { actions: actions, distrust: nil, seen: entries.size }
    end

    def plan_create(entry, record, taken, grouping_id, app_url, now)
      name = BadgeContent.choose_name(entry.name, entry.token_id, current: nil, taken: taken)
      return { token_id: entry.token_id, op: :skip, error: 'no free badge name', attrs: {}, image_source: nil, record: record } unless name

      taken << BadgeContent.name_key(name)
      attrs = desired_attrs(entry, name, entry.description, grouping_id, app_url)
      {
        token_id: entry.token_id, op: :create, attrs: attrs, image_source: entry.image_source,
        record: (record || {}).merge(base_record(entry, name, now)).merge(
          archived: false, absent_runs: 0, badge_id: nil, image_source: nil, image_upload_id: nil, image_hash: nil,
        ),
      }
    end

    def plan_existing(entry, record, snapshot, taken, grouping_id, app_url, now)
      own_key = BadgeContent.name_key(snapshot[:name])
      others = taken - [own_key]
      name = BadgeContent.choose_name(entry.name, entry.token_id, current: snapshot[:name], taken: others) || snapshot[:name]
      taken.delete(own_key)
      taken << BadgeContent.name_key(name)

      # Unknown description: keep what the badge has.
      description = entry.description || snapshot[:description].to_s
      attrs = desired_attrs(entry, name, description, grouping_id, app_url)
      attrs.delete(:description) if entry.description.nil?
      attrs.reject! { |key, value| snapshot[key] == value || (value.nil? && snapshot[key].nil?) }
      attrs.delete(:badge_grouping_id) if grouping_id.nil?

      image_needed = entry.image_source &&
                     (record[:image_source] != entry.image_source || record[:image_upload_id].nil? ||
                      snapshot[:image_upload_id] != record[:image_upload_id])

      changed_record = record[:name_chain] != name || record[:uri] != entry.uri || record[:archived] ||
                       record[:absent_runs].to_i.positive? || record[:official] != entry.official || seen_stale?(record, now)
      return nil if attrs.empty? && !image_needed && !changed_record

      op = if record[:archived] then :unarchive
           elsif attrs.empty? && !image_needed then :seen
           else :update
           end
      {
        token_id: entry.token_id, op: op, attrs: attrs, image_source: image_needed ? entry.image_source : nil,
        record: record.merge(base_record(entry, name, now)).merge(archived: false, absent_runs: 0),
      }
    end

    def seen_stale?(record, now)
      return true if record[:last_seen_at].to_s.empty?

      now - Time.parse(record[:last_seen_at].to_s) > SEEN_REFRESH_SECONDS
    rescue ArgumentError
      true
    end

    def base_record(entry, name, now)
      {
        token_id: entry.token_id, uri: entry.uri, name_chain: name, official: entry.official,
        last_seen_at: now.utc.iso8601
      }
    end

    def desired_attrs(entry, name, description, grouping_id, app_url)
      attrs = {
        name: name,
        description: description.to_s.empty? ? nil : description,
        long_description: BadgeContent.long_description(description, entry.token_id, app_url: app_url),
        badge_type_id: entry.official ? TYPE_OFFICIAL : TYPE_COMMUNITY,
        enabled: true,
        listable: true,
        allow_title: false,
        multiple_grant: false,
      }
      attrs[:badge_grouping_id] = grouping_id if grouping_id
      attrs
    end
  end
end
