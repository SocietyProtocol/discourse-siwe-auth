#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit tests for the on-chain badge mirror: content sanitising, URL
# normalisation, name collisions, the gateway client, the catalog planner and
# the orchestrator's safety rules. No Discourse or network needed.
#
# Run: ruby -r./test/support/pure_keccak -rtime test/badge_mirror_unit_test.rb

require 'json'
require 'set'
require 'time'
require 'minitest/autorun'
require_relative '../lib/discourse_siwe/eth_rpc'
require_relative '../lib/discourse_siwe/badge_ownership'
require_relative '../lib/discourse_siwe/group_sync_planner'
require_relative '../lib/discourse_siwe/badge_content'
require_relative '../lib/discourse_siwe/subgraph_client'
require_relative '../lib/discourse_siwe/badge_catalog'
require_relative '../lib/discourse_siwe/badge_mirror'

Content = DiscourseSiwe::BadgeContent
Catalog = DiscourseSiwe::BadgeCatalog
Mirror = DiscourseSiwe::BadgeMirror
Gateway = DiscourseSiwe::SubgraphClient

NOW = Time.utc(2026, 11, 5, 12, 0, 0)

class ContentTest < Minitest::Test
  def test_html_and_script_are_removed
    assert_equal 'Hello world', Content.plain_text('<b>Hello</b> <script>alert(1)</script>world', 100)
    assert_equal 'Hi', Content.plain_text('<img src=x onerror=alert(1)>Hi', 100)
  end

  def test_entities_cannot_smuggle_tags_back_in
    refute_match(/[<>]/, Content.plain_text('&lt;script&gt;alert(1)&lt;/script&gt;', 100))
  end

  def test_markdown_links_images_and_urls_are_stripped
    text = 'See [the docs](https://evil.test/x) ![pic](https://evil.test/p.png) and https://evil.test/y or www.evil.test now'
    assert_equal 'See the docs and or now', Content.plain_text(text, 200)
  end

  def test_markdown_markers_are_stripped
    assert_equal 'Title bold code', Content.plain_text("# Title\n**bold** `code`", 100)
    assert_equal 'one two', Content.plain_text("- one\n- two", 100)
  end

  def test_invisible_and_control_characters_are_removed
    assert_equal 'Admin', Content.plain_text("Ad​min‮\u0007", 100)
  end

  def test_length_is_capped_with_an_ellipsis
    out = Content.plain_text('a' * 600, Content::DESCRIPTION_MAX)
    assert_equal 500, out.length
    assert out.end_with?("…")
  end

  def test_invalid_bytes_are_dropped
    assert_equal 'ab', Content.plain_text("a\xFFb".dup.force_encoding('UTF-8'), 10)
  end

  def test_blank_and_non_string_input
    assert_equal '', Content.plain_text(nil, 10)
    assert_nil Content.name('   ')
    assert_nil Content.name('<i></i>')
  end

  def test_names_are_capped_at_fifty
    assert_equal 50, Content.name('x' * 80).length
  end

  # ---- hostile text (review findings) ----------------------------------

  # What Discourse does to a description on save: sanitise, then unescape the
  # entities of the result. Anything that is HTML after this is a leak.
  def discourse_unescaped(text)
    CGI.unescapeHTML(text.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;'))
  end

  def test_double_encoded_entities_cannot_become_html_after_discourses_own_unescape
    ['&amp;lt;a href=&amp;quot;//evil.com&amp;quot;&amp;gt;Official airdrop&amp;lt;/a&amp;gt;',
     '&amp;lt;img src=x onerror=alert(1)&amp;gt;', '&amp;amp;amp;amp;amp;amp;amp;lt;b&amp;amp;amp;amp;amp;amp;amp;gt;',
     '&ltscript&gt;alert(1)&lt;/script&gt;', '&#x3C;a href=x&#x3E;', '＆lt；b＆gt；'].each do |hostile|
      out = Content.plain_text(hostile, 500)
      refute_match(/[<>]/, out, hostile)
      refute_match(/&/, out, hostile)
      refute_match(/[<>]/, discourse_unescaped(out), hostile)
    end
    assert_equal 'Official airdrop', Content.plain_text('&amp;lt;a href=&amp;quot;//evil.com&amp;quot;&amp;gt;Official airdrop&amp;lt;/a&amp;gt;', 500)
  end

  def test_entity_encoded_urls_are_still_removed
    assert_equal 'x', Content.plain_text('h&amp;#116;tps://evil.com x', 100)
    assert_equal 'x', Content.plain_text('h&#116;tps://evil.com x', 100)
    refute_includes Content.plain_text('www&#46;evil.test', 100), 'evil'
  end

  def test_an_ampersand_is_kept_as_a_harmless_lookalike
    assert_equal "R\uFF06D", Content.plain_text('R&D', 100)
  end

  def test_invisible_characters_cannot_be_smuggled_in_as_entities
    assert_equal 'Moderator', Content.name('&#x202E;Moderator')
    assert_equal 'Admin', Content.name('Admin&#x200B;')
    assert_equal 'Admin', Content.name('Admin&amp;#x200B;')
    assert_equal 'a b', Content.plain_text('a&#0;b', 100)
    assert_equal 'ok', Content.plain_text('&#xD800;&#x110000;ok', 100).delete("\uFF06#x0123456789;")
  end

  def test_invisible_format_and_control_characters_are_removed_by_category
    ["\u061C", "\u00AD", "\u180E", "\u034F", "\uFE0F", "\u3164", "\uFFA0", "\u115F", "\u{E0041}", "\u{E0100}", "\u2060", "\uFEFF",
     "\u200D", "\u202E", "\u2066", "\u009B", "\u0085", "\u0007", "\u0000"].each do |ch|
      out = Content.name("Mod#{ch}erator")
      assert_match(/\AMod ?erator\z/, out, "U+#{ch.ord.to_s(16)} survived: #{out.inspect}")
      refute_match(/[\p{Cf}\p{Cc}\uFE0F\u061C\u180E\u034F\u3164]/, out)
    end
  end

  def test_unicode_spaces_collapse_and_a_blank_looking_name_is_nil
    assert_equal 'a b c', Content.plain_text("a\u00A0b\u3000c", 100)
    assert_equal 'a b', Content.plain_text("  a\u2003\u2009b\u00A0 ", 100)
    assert_nil Content.name(" \u3000\u00A0\u200B")
  end

  def test_names_are_nfkc_normalised
    assert_equal 'Admin', Content.name("\uFF21\uFF44\uFF4D\uFF49\uFF4E")
  end

  def test_name_keys_ignore_case_spaces_invisibles_and_compatibility_forms
    key = Content.name_key('Moderator')
    ["Moderator\u00A0", "Moder\u200Bator", 'MODERATOR', "\uFF2Doderator", "  Moderator\u3000", "Moderator\u061C"].each do |variant|
      assert_equal key, Content.name_key(variant), variant.inspect
    end
    assert_equal Content.name_key('First Like'), Content.name_key("first\u00A0\u00A0like")
    assert_equal 'first_like', Content.name_key('First  Like')
  end

  def test_a_lookalike_of_a_taken_name_is_suffixed
    taken = Set.new([Content.name_key('Moderator')])
    assert_equal 'Moderator (#9)', Content.choose_name("Moderator\u00A0", 9, taken: taken)
    assert_equal 'Moderator (#9)', Content.choose_name("Moderator\u200B", 9, taken: taken)
  end

  def test_percent_sequences_can_never_reach_i18n_interpolation
    ['%{base_uri} hi', '%{x}', '%<a>d', '%%{scope}', '100% sure', '%{max_likes_per_day}'].each do |hostile|
      out = Content.plain_text(hostile, 500)
      refute_includes out, '%', hostile
      refute_includes Content.name(hostile).to_s, '%'
      refute_includes Content.long_description(hostile, 1, app_url: 'https://app.example.com'), '%'
    end
    assert_equal '100 percent sure', Content.plain_text('100% sure', 100)
  end

  def test_hostile_megabyte_inputs_finish_quickly
    hostile = ['a@' * 600_000, '<script ' * 130_000, '<' * 1_000_000, '<!--' * 250_000, '![' * 500_000, '[a](' * 250_000,
               '[a][' * 250_000, ' ' * 1_000_000 + '1.', '&amp;' * 200_000, 'http://' * 140_000, "\n#" * 500_000, '[' * 1_000_000,
               "\uFDFA" * 100_000, '&#x0' * 250_000, "\t" * 1_000_000 + '-']
    hostile.each do |input|
      started = Time.now
      Content.plain_text(input, Content::DESCRIPTION_MAX)
      Content.name(input)
      Content.long_description(input, 1, app_url: 'https://app.example.com')
      assert_operator Time.now - started, :<, 1.0, "#{input[0, 12].inspect} took #{Time.now - started}s"
    end
  end

  def test_input_is_cut_before_any_pattern_runs
    out = Content.plain_text("#{'x' * Content::INPUT_MAX} secret-tail-marker", 100_000)
    refute_includes out, 'secret-tail-marker'
    assert_operator out.length, :<=, Content::INPUT_MAX
  end

  def test_token_ids_are_plain_decimals_only
    assert_equal 13, Content.token_id('13')
    assert_equal 13, Content.token_id(13)
    assert_nil Content.token_id('0x0d')
    assert_nil Content.token_id('13; drop')
    assert_nil Content.token_id(nil)
  end
end

class NameTest < Minitest::Test
  def taken(*names)
    Set.new(names.map { |n| Content.name_key(n) })
  end

  def test_a_free_name_is_used_as_is
    assert_equal 'Governor', Content.choose_name('Governor', 13, taken: taken('Member'))
  end

  def test_a_collision_gets_the_token_id_suffix
    assert_equal 'Member (#80)', Content.choose_name('Member', 80, taken: taken('Member'))
  end

  def test_collision_is_case_and_space_insensitive_because_discourse_resolves_names_that_way
    assert_equal 'welcome (#9)', Content.choose_name('welcome', 9, taken: taken('Welcome'))
    assert_equal 'First Like (#9)', Content.choose_name('First Like', 9, taken: taken('first_like'))
  end

  def test_the_suffix_fits_inside_the_cap
    name = Content.choose_name('x' * 80, 123, taken: taken(Content.name('x' * 80)))
    assert name.length <= 50
    assert name.end_with?(' (#123)')
  end

  def test_a_suffixed_name_is_stable_even_after_the_collision_goes_away
    assert_equal 'Member (#80)', Content.choose_name('Member', 80, current: 'Member (#80)', taken: taken)
  end

  def test_a_plain_name_is_stable
    assert_equal 'Governor', Content.choose_name('Governor', 13, current: 'Governor', taken: taken('Other'))
  end

  def test_a_real_chain_rename_renames_the_badge
    assert_equal 'Council', Content.choose_name('Council', 13, current: 'Governor', taken: taken)
  end

  def test_a_manual_edit_is_overwritten
    assert_equal 'Governor', Content.choose_name('Governor', 13, current: 'My own name', taken: taken)
  end

  def test_blank_chain_name_falls_back_to_the_token_id
    assert_equal 'Society badge #7', Content.choose_name('<b></b>', 7, taken: taken)
  end

  def test_nil_when_every_candidate_is_taken
    assert_nil Content.choose_name('A', 5, taken: taken('A', 'A (#5)', 'Society badge #5'))
  end
end

class ImageUrlTest < Minitest::Test
  CID = 'bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi'
  QM = 'QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG'
  GW = 'https://ipfs.filebase.io/ipfs/'

  def test_ipfs_scheme
    assert_equal "#{GW}#{CID}/badge.png", Content.image_url("ipfs://#{CID}/badge.png")
    assert_equal "#{GW}#{CID}", Content.image_url("ipfs://ipfs/#{CID}")
  end

  def test_path_style_gateways_and_relative_ipfs_paths_keep_the_subpath
    assert_equal "#{GW}#{CID}/a.png", Content.image_url("https://dweb.link/ipfs/#{CID}/a.png")
    assert_equal "#{GW}#{CID}/a.png", Content.image_url("/ipfs/#{CID}/a.png")
    assert_equal "#{GW}#{CID}", Content.image_url("http://gateway.pinata.cloud/ipfs/#{CID}")
  end

  def test_bare_cids
    assert_equal "#{GW}#{QM}", Content.image_url(QM)
    assert_equal "#{GW}#{CID}", Content.image_url(CID)
  end

  def test_plain_https_is_kept
    assert_equal 'https://cdn.example.com/b.png', Content.image_url('https://cdn.example.com/b.png')
  end

  def test_everything_else_is_rejected
    ['data:image/png;base64,AAAA', 'http://cdn.example.com/b.png', 'ftp://x/y.png', 'javascript:alert(1)',
     'file:///etc/passwd', 'https://user:pw@cdn.example.com/b.png', 'https:///nohost', 'ipfs://', '',
     nil, 'https://a.example/' + ('x' * 3000), "https://a.example/b c.png"].each do |bad|
      assert_nil Content.image_url(bad), "should reject #{bad.to_s[0, 40].inspect}"
    end
  end

  def test_only_real_image_types_are_allowed
    assert Content.image_type_allowed?(:png)
    assert Content.image_type_allowed?(:svg)
    refute Content.image_type_allowed?(:html)
    refute Content.image_type_allowed?(nil)
  end
end

class LongDescriptionTest < Minitest::Test
  LINK = '<a href="https://app.example.com/badges/13">View this badge in the outpost</a>'

  def test_includes_our_link_as_html_only_for_an_https_app_url
    with = Content.long_description('Hi', 13, app_url: 'https://app.example.com/')
    assert with.end_with?(LINK), with
    assert_includes with, 'Hi<br><br>Mirrored from'
    refute_includes with, '](' # no markdown: Discourse renders this field as sanitised HTML
    refute_includes Content.long_description('Hi', 13, app_url: 'http://app.example.com'), 'View this badge'
    refute_includes Content.long_description('Hi', 13), 'View this badge'
  end

  def test_the_app_url_setting_is_never_trusted
    ['https://app.example.com/"><script>alert(1)</script>', 'https://app.example.com/" onclick="x', "https://app.example.com/a'b",
     'https://user:pw@app.example.com', 'https://app.example.com?x=1', 'https://app.example.com#frag', 'javascript:alert(1)',
     'https://', 'https:///x', 'https://app example.com', "https://app.example.com/\nx", 'https://app.example.com/a%7Bb',
     'https://app.example.com/%{base_uri}', 'https://ap<p.example.com', 'ftp://app.example.com', "https://#{'a' * 300}.com",
     'https://app.example.com/a&b', 'https://app.example.com/a<b', "https://app.example.com\\evil.com", 'https://exämple.com'].each do |bad|
      assert_equal '', Content.app_url(bad), bad
      out = Content.long_description('Hi', 13, app_url: bad)
      refute_includes out, '<a ', bad
      refute_includes out, 'script'
    end
  end

  def test_app_url_normalisation
    assert_equal 'https://app.example.com', Content.app_url(' https://app.example.com/// ')
    assert_equal 'https://app.example.com:8443/outpost', Content.app_url('https://app.example.com:8443/outpost/')
    assert_equal '', Content.app_url(nil)
    assert_equal '', Content.app_url('   ')
  end

  def test_stays_under_the_discourse_limit_and_never_cuts_the_markup
    ['d' * 500, 'd ' * 900, "<b>x</b>#{'é' * 800}"].each do |description|
      out = Content.long_description(description, 13, app_url: 'https://app.example.com')
      assert out.length <= 1000, out.length
      assert out.end_with?(LINK), out
      assert_equal 1, out.scan('<a ').size
      assert_equal 1, out.scan('</a>').size
      refute_includes out, '<b>'
    end
  end

  def test_the_description_inside_is_plain_text
    out = Content.long_description('&amp;lt;img src=x onerror=1&amp;gt; %{x} https://evil.test', 13, app_url: '')
    refute_match(/[<&%]/, out.gsub('<br><br>', ''))
    refute_includes out, 'evil.test'
  end

  def test_stays_under_the_limit_without_a_link
    assert Content.long_description('d' * 500, 13).length <= 1000
  end
end

class FakeHttp
  Response = Struct.new(:code, :body)
  class << self
    attr_accessor :requests, :replies
  end
  attr_writer :use_ssl, :open_timeout, :read_timeout

  def request(req)
    self.class.requests << req
    reply = self.class.replies.shift
    raise reply if reply.is_a?(Exception)

    Response.new(reply[0].to_s, reply[1].is_a?(String) ? reply[1] : reply[1].to_json)
  end
end

class SubgraphClientTest < Minitest::Test
  def setup
    FakeHttp.requests = []
    FakeHttp.replies = []
  end

  def client(token: 'secret-token')
    Gateway.new(url: 'http://prod-gateway:8080/graphql', token: token, http_factory: ->(_uri) { FakeHttp.new })
  end

  def test_sends_the_exact_document_operation_variables_and_bearer
    FakeHttp.replies = [[200, { 'data' => { 'badges' => [] } }]]
    client.query(operation: 'Badges', document: Catalog::DOCUMENT, variables: Catalog.variables(1000, 0))
    req = FakeHttp.requests.first
    body = JSON.parse(req.body)
    assert_equal 'Bearer secret-token', req['Authorization']
    assert_equal 'Badges', body['operationName']
    assert_equal Catalog::DOCUMENT, body['query']
    assert_equal({ 'isProfile' => false }, body['variables']['where'])
    assert_equal 'id', body['variables']['orderBy']
    assert_equal 1000, body['variables']['first']
  end

  def test_no_authorization_header_without_a_token
    FakeHttp.replies = [[200, { 'data' => {} }]]
    client(token: '').query(operation: 'Badges', document: 'q', variables: {})
    assert_nil FakeHttp.requests.first['Authorization']
  end

  def test_every_failure_raises_and_leaks_neither_url_nor_token
    [[401, '{}'], [500, 'oops'], [200, 'not json'], [200, [1, 2]], [200, { 'errors' => [{ 'message' => 'bad' }] }],
     [200, { 'data' => nil }], [200, { 'x' => 1 }], SocketError.new('getaddrinfo prod-gateway')].each do |reply|
      FakeHttp.replies = [reply.is_a?(Exception) ? reply : [reply[0], reply[1]]]
      error = assert_raises(Gateway::Error) { client.query(operation: 'Badges', document: 'q', variables: {}) }
      refute_includes error.message, 'prod-gateway'
      refute_includes error.message, 'secret-token'
    end
  end

  def test_blank_url_raises
    assert_raises(Gateway::Error) { Gateway.new(url: ' ').query(operation: 'x', document: 'q', variables: {}) }
  end

  def test_paginate_stops_on_a_short_page_and_refuses_a_truncated_read
    page = ->(n) { [200, { 'data' => { 'badges' => Array.new(n) { |i| { 'id' => i.to_s } } } }] }
    FakeHttp.replies = [page.call(2), page.call(1)]
    rows = client.paginate(operation: 'Badges', document: 'q', page_size: 2, variables_for: ->(f, s) { { first: f, skip: s } }, extract: ->(d) { d['badges'] })
    assert_equal 3, rows.size
    assert_equal 2, JSON.parse(FakeHttp.requests.last.body)['variables']['skip']

    FakeHttp.replies = [page.call(2), page.call(2)]
    assert_raises(Gateway::Error) do
      client.paginate(operation: 'Badges', document: 'q', page_size: 2, max_pages: 2, variables_for: ->(f, s) { { first: f, skip: s } }, extract: ->(d) { d['badges'] })
    end
  end

  def test_the_embedded_document_matches_the_gateway_registry_when_it_is_available
    registry = File.expand_path('../../web3-app-subgraph/infra/query-gateway/generated/registry.js', __dir__)
    skip 'gateway registry not checked out next to the plugin' unless File.exist?(registry)

    text = File.read(registry)[/"Badges": Object\.freeze\(\{\s*sha256: "[0-9a-f]+",\s*query: (".*?"),\n/m, 1]
    refute_nil text
    assert_equal JSON.parse(text).strip, Catalog::DOCUMENT.strip
  end
end

class CatalogParseTest < Minitest::Test
  def row(id, extra = {})
    { 'id' => id.to_s, 'name' => "Badge #{id}", 'isOfficial' => true, 'isCommunity' => false, 'uri' => "ipfs://x/#{id}",
      'description' => nil, 'imageUrl' => nil, 'metadata' => { 'description' => "About #{id}", 'imageUrl' => 'ipfs://bafy/a.png' } }.merge(extra)
  end

  def test_top_level_description_and_image_are_ignored_because_the_subgraph_nulls_them
    entry = Catalog.parse([row(13, 'description' => 'ignored', 'imageUrl' => 'https://x/ignored.png')])[:entries].first
    assert_equal 'About 13', entry.description
    assert_equal 'https://ipfs.filebase.io/ipfs/bafy/a.png', entry.image_source
  end

  def test_null_metadata_means_unknown_not_empty
    entry = Catalog.parse([row(13, 'metadata' => nil)])[:entries].first
    assert_nil entry.description
    assert_nil entry.image_source
  end

  def test_blank_or_unusable_metadata_values_are_unknown
    entry = Catalog.parse([row(13, 'metadata' => { 'description' => '  ', 'imageUrl' => 'data:image/png;base64,AA' })])[:entries].first
    assert_nil entry.description
    assert_nil entry.image_source
  end

  def test_bad_and_duplicate_rows_are_rejected_and_ids_sorted
    parsed = Catalog.parse([row(30), row(3), row(3), { 'id' => 'zz' }, nil])
    assert_equal [3, 30], parsed[:entries].map(&:token_id)
    assert_equal 3, parsed[:rejected]
  end

  def test_scope_is_official_plus_allowlisted_community
    official = Catalog::Entry.new(token_id: 1, official: true, community: false)
    community = Catalog::Entry.new(token_id: 2, official: false, community: true)
    assert Catalog.in_scope?(official, Set.new)
    refute Catalog.in_scope?(community, Set.new)
    assert Catalog.in_scope?(community, Set.new([2]))
    refute Catalog.in_scope?(Catalog::Entry.new(token_id: 3, official: false, community: false), Set.new([3]))
  end
end

# In-memory stand-in for the Discourse side.
class World
  attr_reader :records, :badge_rows, :user_badges, :writes, :pending, :meta, :grants_log, :revokes_log
  attr_accessor :hold, :images, :taken_extra, :grant_result

  def initialize
    @records = {}
    @badge_rows = {}
    @user_badges = Hash.new { |h, k| h[k] = Set.new }
    @writes = []
    @pending = {}
    @meta = {}
    @hold = false
    @next_badge_id = 100
    @grants_log = []
    @revokes_log = []
    @images = ->(_url) { { upload_id: 9, hash: 'abc' } }
    @taken_extra = Set.new
    @grant_result = true
  end

  # store
  def records_for_store
    @records.dup
  end

  def save_record(record)
    @writes << [:save_record, record[:token_id]]
    @records[record[:token_id]] = record
  end

  def save_meta(hash)
    @writes << [:save_meta]
    @meta = hash
  end

  def save_pending(hash)
    @writes << [:save_pending]
    @pending = hash
  end

  def set_hold(value)
    @writes << [:set_hold, value]
    @hold = value
  end

  def hold?
    @hold
  end

  # badges
  def snapshots(records)
    records.each_with_object({}) { |(token, rec), h| h[token] = rec[:badge_id] && @badge_rows[rec[:badge_id]]&.dup }
  end

  def taken_names
    Set.new(@badge_rows.values.map { |r| Content.name_key(r[:name]) }) | @taken_extra
  end

  def grouping_id(create:)
    @writes << [:grouping] if create && !@grouping_made
    @grouping_made ||= create
    @grouping_made ? 5 : nil
  end

  def create(attrs)
    @writes << [:badge_create, attrs[:name]]
    id = (@next_badge_id += 1)
    @badge_rows[id] = attrs.merge(image_upload_id: nil)
    id
  end

  def update(badge_id, attrs)
    @writes << [:badge_update, badge_id, attrs.keys.sort]
    @badge_rows[badge_id].merge!(attrs)
  end

  # grants
  def holders(badge_id)
    @user_badges[badge_id].dup
  end

  def grant(badge_id, user_id, suppress:)
    @writes << [:grant, badge_id, user_id]
    @grants_log << [badge_id, user_id, suppress]
    @user_badges[badge_id] << user_id if @grant_result
    @grant_result
  end

  def revoke(badge_id, user_id)
    @writes << [:revoke, badge_id, user_id]
    @revokes_log << [badge_id, user_id]
    @user_badges[badge_id].delete(user_id)
  end

  # collaborator views
  def store
    me = self
    Object.new.tap do |o|
      o.define_singleton_method(:records) { me.records_for_store }
      o.define_singleton_method(:save_record) { |r| me.save_record(r) }
      o.define_singleton_method(:meta) { me.meta }
      o.define_singleton_method(:save_meta) { |h| me.save_meta(h) }
      o.define_singleton_method(:pending) { me.pending }
      o.define_singleton_method(:save_pending) { |h| me.save_pending(h) }
      o.define_singleton_method(:hold?) { me.hold? }
      o.define_singleton_method(:set_hold) { |v| me.set_hold(v) }
    end
  end

  def image_fetcher
    me = self
    ->(url) { me.images.call(url) }
  end

  def writes_except_reads
    @writes
  end
end

module MirrorHelpers
  A = '0x' + 'a1' * 20
  B = '0x' + 'b2' * 20
  C = '0x' + 'c3' * 20
  D = '0x' + 'd4' * 20
  E = '0x' + 'e5' * 20 # an EOA
  S = '0x' + '51' * 20 # the Light Account it owns

  def row(id, extra = {})
    { 'id' => id.to_s, 'name' => "Badge #{id}", 'isOfficial' => true, 'isCommunity' => false, 'uri' => "ipfs://x/#{id}",
      'metadata' => { 'description' => "About #{id}", 'imageUrl' => 'ipfs://bafy/a.png' } }.merge(extra)
  end

  def user(id, *addresses)
    { id: id, username: "user#{id}", addresses: addresses }
  end

  # holdings: { address => { token => Integer|nil } }
  def mirror(world, rows: [row(13)], users: [], holdings: {}, config: {}, catalog: :rows, ownership: nil, now: NOW)
    catalog_proc = case catalog
                   when :rows then -> { rows }
                   when :none then nil
                   else catalog
                   end
    chain = ownership || lambda do |addresses, _ids|
      addresses.each_with_object(Hash.new { |h, k| h[k] = {} }) { |a, h| h[a] = (holdings[a] || {}).dup }
    end
    Mirror.new(
      catalog: catalog_proc, store: world.store, badges: world, images: world.image_fetcher, grants: world,
      users: users, ownership: chain, config: Mirror.config(**config), now: -> { now },
    )
  end

  def usernames_of(world, badge_id)
    world.user_badges[badge_id].to_a.sort
  end
end

class MirrorCatalogTest < Minitest::Test
  include MirrorHelpers

  def test_first_enforce_run_creates_the_badge_with_sane_attributes_and_the_image
    world = World.new
    report = mirror(world).run(mode: 'enforce')
    assert_equal [13], report[:catalog][:created]
    badge = world.badge_rows.values.first
    assert_equal 'Badge 13', badge[:name]
    assert_equal 'About 13', badge[:description]
    assert_equal 1, badge[:badge_type_id]
    assert_equal 5, badge[:badge_grouping_id]
    assert_equal false, badge[:multiple_grant]
    assert_equal 9, badge[:image_upload_id]
    record = world.records[13]
    assert_equal 'https://ipfs.filebase.io/ipfs/bafy/a.png', record[:image_source]
    assert_equal 9, record[:image_upload_id]
    assert_equal 'abc', record[:image_hash]
    assert_equal 1, world.meta[:count]
  end

  def test_second_run_changes_nothing
    world = World.new
    mirror(world).run(mode: 'enforce')
    world.writes.clear
    report = mirror(world).run(mode: 'enforce')
    assert_equal [], report[:catalog][:created] + report[:catalog][:updated] + report[:catalog][:archived]
    assert_equal [], world.writes.reject { |w| %i[save_meta set_hold save_pending].include?(w.first) }
  end

  def test_null_metadata_keeps_the_existing_description_and_image
    world = World.new
    mirror(world).run(mode: 'enforce')
    world.writes.clear
    report = mirror(world, rows: [row(13, 'metadata' => nil)]).run(mode: 'enforce')
    badge = world.badge_rows.values.first
    assert_equal 'About 13', badge[:description]
    assert_equal 9, badge[:image_upload_id]
    assert_equal [], report[:catalog][:updated]
    assert_equal [], world.writes.select { |w| %i[badge_update badge_create].include?(w.first) }
  end

  def test_a_changed_description_and_image_are_updated_and_refetched
    world = World.new
    mirror(world).run(mode: 'enforce')
    fetched = []
    world.images = ->(url) { fetched << url; { upload_id: 10, hash: 'def' } }
    changed = row(13, 'metadata' => { 'description' => 'New text', 'imageUrl' => 'https://cdn.example.com/n.png' })
    report = mirror(world, rows: [changed]).run(mode: 'enforce')
    assert_equal [13], report[:catalog][:updated]
    assert_equal 'New text', world.badge_rows.values.first[:description]
    assert_equal ['https://cdn.example.com/n.png'], fetched
    assert_equal 10, world.badge_rows.values.first[:image_upload_id]
  end

  def test_a_failed_image_fetch_keeps_the_old_image
    world = World.new
    mirror(world).run(mode: 'enforce')
    world.images = ->(_url) { nil }
    changed = row(13, 'metadata' => { 'description' => 'About 13', 'imageUrl' => 'https://cdn.example.com/n.png' })
    report = mirror(world, rows: [changed]).run(mode: 'enforce')
    assert_equal 1, report[:catalog][:images][:failed]
    assert_equal 9, world.badge_rows.values.first[:image_upload_id]
    assert_equal 'https://ipfs.filebase.io/ipfs/bafy/a.png', world.records[13][:image_source]
  end

  def test_image_fetches_per_run_are_bounded
    world = World.new
    rows = (1..5).map { |i| row(i, 'metadata' => { 'description' => 'd', 'imageUrl' => "https://cdn.example.com/#{i}.png" }) }
    report = mirror(world, rows: rows, config: { max_images: 2 }).run(mode: 'enforce')
    assert_equal 2, report[:catalog][:images][:fetched]
    assert_equal 3, report[:catalog][:images][:deferred]
    mirror(world, rows: rows, config: { max_images: 2 }).run(mode: 'enforce')
    assert_equal 4, world.records.values.count { |r| r[:image_upload_id] }
  end

  def test_name_collision_gets_a_suffix_and_stays_stable
    world = World.new
    world.taken_extra = Set.new([Content.name_key('Badge 13')])
    mirror(world).run(mode: 'enforce')
    assert_equal 'Badge 13 (#13)', world.badge_rows.values.first[:name]
    world.taken_extra = Set.new # the other badge is gone; do not rename
    world.writes.clear
    mirror(world).run(mode: 'enforce')
    assert_equal 'Badge 13 (#13)', world.badge_rows.values.first[:name]
    assert_empty world.writes.select { |w| w.first == :badge_update }
  end

  def test_a_manual_edit_of_a_synced_badge_is_overwritten
    world = World.new
    mirror(world).run(mode: 'enforce')
    world.badge_rows.values.first.merge!(name: 'Hacked', description: 'Hacked', enabled: false)
    mirror(world).run(mode: 'enforce')
    row = world.badge_rows.values.first
    assert_equal ['Badge 13', 'About 13', true], [row[:name], row[:description], row[:enabled]]
  end

  def test_community_badges_need_the_allowlist
    world = World.new
    rows = [row(13), row(80, 'isOfficial' => false, 'isCommunity' => true)]
    mirror(world, rows: rows).run(mode: 'enforce')
    assert_equal [13], world.records.keys
    mirror(world, rows: rows, config: { allowlist: Set.new([80]) }).run(mode: 'enforce')
    assert_equal [13, 80], world.records.keys.sort
    assert_equal 2, world.badge_rows[world.records[80][:badge_id]][:badge_type_id] # community type
  end

  def test_untrusted_chain_text_is_sanitised_before_it_reaches_the_forum
    world = World.new
    evil = row(13, 'name' => '<b>Gov</b>ernor [x](https://evil.test)', 'metadata' => { 'description' => '<script>x</script>Visit https://evil.test', 'imageUrl' => nil })
    mirror(world, rows: [evil]).run(mode: 'enforce')
    badge = world.badge_rows.values.first
    assert_equal 'Governor x', badge[:name]
    assert_equal 'Visit', badge[:description]
    refute_includes badge[:long_description], 'evil.test'
  end

  def test_a_missing_badge_row_is_recreated
    world = World.new
    mirror(world).run(mode: 'enforce')
    world.badge_rows.clear
    report = mirror(world).run(mode: 'enforce')
    assert_equal [13], report[:catalog][:created]
    assert world.badge_rows[world.records[13][:badge_id]]
  end

  def test_a_recreated_badge_is_a_fresh_silent_backfill_not_a_notification_for_every_holder
    world = World.new
    mirror(world).run(mode: 'enforce')
    mirror(world, users: [user(1, A)], holdings: { A => { 13 => 1 } }).run(mode: 'enforce')
    assert world.records[13][:backfilled]
    old_badge = world.records[13][:badge_id]
    world.badge_rows.clear # an admin deleted the badge
    world.grants_log.clear

    users = [user(1, A), user(2, B), user(3, C)]
    holdings = { A => { 13 => 1 }, B => { 13 => 1 }, C => { 13 => 1 } }
    later = NOW + 3600
    report = mirror(world, users: users, holdings: holdings, now: later).run(mode: 'enforce')
    assert_equal [13], report[:catalog][:created]
    refute_equal old_badge, world.records[13][:badge_id]
    assert_equal [true, true, true], world.grants_log.map(&:last), 'a rebuilt badge must be granted silently'
    assert world.records[13][:backfilled], 'and be marked backfilled after its first pass'
    assert_equal later.utc.iso8601, world.records[13][:last_seen_at]

    mirror(world, users: users + [user(4, D)], holdings: holdings.merge(D => { 13 => 1 }), now: later + 3600).run(mode: 'enforce')
    assert_equal false, world.grants_log.last.last, 'later holders are notified again'
  end

  def test_a_recreated_badge_resets_its_image_state
    world = World.new
    mirror(world).run(mode: 'enforce')
    world.badge_rows.clear
    fetched = []
    world.images = ->(url) { fetched << url; { upload_id: 77, hash: 'new' } }
    mirror(world).run(mode: 'enforce')
    assert_equal 1, fetched.size
    assert_equal 77, world.records[13][:image_upload_id]
    assert_equal 77, world.badge_rows[world.records[13][:badge_id]][:image_upload_id]
  end

  def test_a_hung_image_download_cannot_stall_the_run
    world = World.new
    world.images = ->(_url) { sleep 10; { upload_id: 1, hash: 'x' } }
    started = Time.now
    report = mirror(world, users: [user(1, A)], holdings: { A => { 13 => 1 } }, config: { image_timeout: 0.2 }).run(mode: 'enforce')
    assert_operator Time.now - started, :<, 3
    assert_equal 1, report[:catalog][:images][:failed]
    assert_equal 0, report[:catalog][:images][:fetched]
    assert_equal :errors, report[:status]
    assert_match(/Timeout/, report[:errors].first)
    assert_equal [world.records[13][:badge_id]], world.user_badges.keys, 'the holder step still ran'
  end

  def test_an_image_that_raises_counts_as_failed
    world = World.new
    world.images = ->(_url) { raise IOError, 'boom' }
    report = mirror(world).run(mode: 'enforce')
    assert_equal 1, report[:catalog][:images][:failed]
    assert_equal [13], world.records.keys
  end

  def test_a_failing_image_source_is_backed_off_for_a_day_unless_the_url_changes
    world = World.new
    calls = []
    world.images = ->(url) { calls << url; nil }
    rows = [row(13)]
    mirror(world, rows: rows, now: NOW).run(mode: 'enforce')
    assert_equal 1, calls.size
    assert_equal NOW.utc.iso8601, world.records[13][:image_failed_at]
    assert_equal 'https://ipfs.filebase.io/ipfs/bafy/a.png', world.records[13][:image_failed_source]

    mirror(world, rows: rows, now: NOW + 3600).run(mode: 'enforce')
    mirror(world, rows: rows, now: NOW + 23 * 3600).run(mode: 'enforce')
    assert_equal 1, calls.size, 'no retry inside 24h'

    mirror(world, rows: rows, now: NOW + 25 * 3600).run(mode: 'enforce')
    assert_equal 2, calls.size, 'retried after 24h'

    other = [row(13, 'metadata' => { 'description' => 'About 13', 'imageUrl' => 'https://cdn.example.com/other.png' })]
    mirror(world, rows: other, now: NOW + 25 * 3600 + 60).run(mode: 'enforce')
    assert_equal 3, calls.size, 'a changed source is tried at once'
    assert_equal 'https://cdn.example.com/other.png', calls.last
  end

  def test_a_success_clears_the_failure_memory
    world = World.new
    world.images = ->(_url) { nil }
    mirror(world, now: NOW).run(mode: 'enforce')
    world.images = ->(_url) { { upload_id: 5, hash: 'ok' } }
    mirror(world, now: NOW + 25 * 3600).run(mode: 'enforce')
    assert_nil world.records[13][:image_failed_at]
    assert_nil world.records[13][:image_failed_source]
    assert_equal 5, world.records[13][:image_upload_id]
  end

  def test_a_failing_badge_create_is_reported_and_does_not_store_a_record
    world = World.new
    world.define_singleton_method(:create) { |_attrs| raise ActiveRecordLike, 'boom' }
    report = mirror(world).run(mode: 'enforce')
    assert_empty world.records
    assert_equal :errors, report[:status]
  end

  class ActiveRecordLike < StandardError; end
end

class MirrorArchiveTest < Minitest::Test
  include MirrorHelpers

  def seeded(count = 4)
    world = World.new
    mirror(world, rows: (1..count).map { |i| row(i) }).run(mode: 'enforce')
    world
  end

  def test_a_badge_that_left_the_chain_is_archived_after_two_runs_never_deleted
    world = seeded
    rows = [row(1), row(2), row(3)]
    first = mirror(world, rows: rows).run(mode: 'enforce')
    assert_equal [], first[:catalog][:archived]
    assert world.badge_rows[world.records[4][:badge_id]][:enabled]
    second = mirror(world, rows: rows).run(mode: 'enforce')
    assert_equal [4], second[:catalog][:archived]
    assert_equal false, world.badge_rows[world.records[4][:badge_id]][:enabled]
    assert world.records[4][:archived]
    assert_equal 4, world.badge_rows.size
  end

  def test_an_archived_badge_comes_back_when_it_reappears
    world = seeded
    rows = [row(1), row(2), row(3)]
    2.times { mirror(world, rows: rows).run(mode: 'enforce') }
    report = mirror(world, rows: (1..4).map { |i| row(i) }).run(mode: 'enforce')
    assert_equal [4], report[:catalog][:unarchived]
    assert world.badge_rows[world.records[4][:badge_id]][:enabled]
    refute world.records[4][:archived]
  end

  def test_a_single_missing_run_is_forgiven
    world = seeded
    mirror(world, rows: [row(1), row(2), row(3)]).run(mode: 'enforce')
    report = mirror(world, rows: (1..4).map { |i| row(i) }).run(mode: 'enforce')
    assert_equal [], report[:catalog][:archived]
    assert_equal 0, world.records[4][:absent_runs]
  end

  def test_an_empty_or_far_smaller_catalog_changes_nothing_and_blocks_revokes
    [[], [row(1)]].each do |rows|
      world = seeded(6)
      world.writes.clear
      3.times { mirror(world, rows: rows).run(mode: 'enforce') }
      assert_equal 6, world.badge_rows.values.count { |b| b[:enabled] }
      assert_empty world.writes.select { |w| %i[badge_update badge_create save_record].include?(w.first) }
    end
  end

  def test_distrust_reason_is_reported_and_blocks_revokes
    world = seeded(6)
    report = mirror(world, rows: [row(1)]).run(mode: 'enforce')
    assert_match(/shrank/, report[:catalog][:distrust])
    assert_match(/not trusted/, report[:revoke_blocked])
  end

  def test_losing_the_official_flag_on_most_badges_at_once_is_not_acted_on
    world = seeded(6)
    rows = (1..6).map { |i| row(i, 'isOfficial' => i <= 3) }
    report = mirror(world, rows: rows).run(mode: 'enforce')
    # 3 of 6 is not "most"; one more tips it over
    assert_nil report[:catalog][:distrust]
    world = seeded(6)
    rows = (1..6).map { |i| row(i, 'isOfficial' => i <= 2) }
    2.times { mirror(world, rows: rows).run(mode: 'enforce') }
    assert_equal 6, world.badge_rows.values.count { |b| b[:enabled] }
  end
end

class MirrorHoldersTest < Minitest::Test
  include MirrorHelpers

  def setup
    @world = World.new
    mirror(@world).run(mode: 'enforce') # creates badge 13 (id 101), silently
    @badge = @world.records[13][:badge_id]
  end

  # Callers pass chain holdings as a braceless trailing hash (address => {...}).
  # Ruby 3 turns that into keywords, so the address keys arrive in opts.
  def run_mirror(users, holdings = {}, **opts)
    mode = opts.delete(:mode) || 'enforce'
    addresses = opts.reject { |key, _| key.is_a?(Symbol) }
    opts = opts.select { |key, _| key.is_a?(Symbol) }
    mirror(@world, users: users, holdings: holdings.merge(addresses), **opts).run(mode: mode)
  end

  def test_holder_is_granted_and_non_holder_is_not
    run_mirror([user(1, A), user(2, B)], A => { 13 => 1 }, B => { 13 => 0 })
    assert_equal [1], usernames_of(@world, @badge)
  end

  def test_holdings_are_the_union_of_s_and_e
    run_mirror([user(1, A, B)], B => { 13 => 2 }) # only the owner EOA holds it
    assert_equal [1], usernames_of(@world, @badge)
  end

  def test_other_members_holdings_do_not_leak
    run_mirror([user(1, A), user(2, B)], B => { 13 => 1 })
    assert_equal [2], usernames_of(@world, @badge)
  end

  def test_existing_holder_stays_without_writes
    @world.user_badges[@badge] << 1
    @world.writes.clear
    run_mirror([user(1, A)], A => { 13 => 1 })
    assert_empty @world.writes.select { |w| %i[grant revoke].include?(w.first) }
  end

  def test_revoke_needs_two_consecutive_runs
    @world.user_badges[@badge] << 1
    run_mirror([user(1, A)], A => { 13 => 0 })
    assert_equal [1], usernames_of(@world, @badge)
    run_mirror([user(1, A)], A => { 13 => 0 })
    assert_equal [], usernames_of(@world, @badge)
  end

  def test_a_balance_that_comes_back_resets_the_counter
    @world.user_badges[@badge] << 1
    run_mirror([user(1, A)], A => { 13 => 0 })
    run_mirror([user(1, A)], A => { 13 => 1 })
    run_mirror([user(1, A)], A => { 13 => 0 })
    assert_equal [1], usernames_of(@world, @badge)
  end

  def test_unknown_balance_never_revokes_even_after_many_runs
    @world.user_badges[@badge] << 1
    5.times { run_mirror([user(1, A), user(2, B)], A => { 13 => nil }, B => { 13 => 1 }) }
    assert_equal [1, 2], usernames_of(@world, @badge)
  end

  def test_unknown_on_one_address_and_zero_on_the_other_is_unknown
    @world.user_badges[@badge] << 1
    3.times { run_mirror([user(1, A, B), user(2, C)], A => { 13 => nil }, B => { 13 => 0 }, C => { 13 => 1 }) }
    assert_equal [1, 2], usernames_of(@world, @badge)
  end

  def test_positive_on_one_address_wins_over_unknown_on_the_other
    run_mirror([user(1, A, B)], A => { 13 => nil }, B => { 13 => 1 })
    assert_equal [1], usernames_of(@world, @badge)
  end

  def test_holders_outside_the_evaluated_set_are_never_touched
    @world.user_badges[@badge].merge([1, 77]) # 77: suspended, silenced, staged or walletless (not in users)
    3.times { run_mirror([user(1, A), user(2, B)], A => { 13 => 0 }, B => { 13 => 1 }) }
    assert_equal [2, 77], usernames_of(@world, @badge)
  end

  def test_a_chain_error_aborts_everything
    @world.user_badges[@badge] << 1
    boom = ->(_a, _i) { raise DiscourseSiwe::BadgeOwnership::SourceError, 'wrong chain' }
    3.times { report = run_mirror([user(1, A)], {}, ownership: boom); assert_equal :source_error, report[:status] }
    assert_equal [1], usernames_of(@world, @badge)
    assert_empty @world.grants_log
    assert_equal true, @world.hold?
  end

  def test_nothing_readable_is_a_source_error
    @world.user_badges[@badge] << 1
    all_nil = ->(addresses, _i) { addresses.each_with_object({}) { |a, h| h[a] = { 13 => nil } } }
    3.times { run_mirror([user(1, A)], {}, ownership: all_nil) }
    assert_equal [1], usernames_of(@world, @badge)
  end

  def test_blank_rpc_error_is_a_source_error
    @world.user_badges[@badge] << 1
    blank = ->(_a, _i) { raise DiscourseSiwe::BadgeOwnership::SourceError, 'RPC URL is not configured' }
    run_mirror([user(1, A)], {}, ownership: blank)
    assert_equal [1], usernames_of(@world, @badge)
  end

  def test_a_catalog_error_blocks_revokes_but_grants_continue
    @world.user_badges[@badge].merge([1])
    failing = -> { raise Gateway::Error, 'gateway HTTP 500' }
    4.times { run_mirror([user(1, A), user(2, B)], { A => { 13 => 0 }, B => { 13 => 1 } }, catalog: failing) }
    assert_equal [1, 2], usernames_of(@world, @badge)
    report = run_mirror([user(1, A), user(2, B)], { A => { 13 => 0 }, B => { 13 => 1 } }, catalog: failing)
    assert_match(/catalog unavailable/, report[:revoke_blocked])
    assert_equal true, @world.hold?
  end

  def test_a_clean_full_run_clears_the_hold
    @world.hold = true
    run_mirror([user(1, A)], A => { 13 => 1 })
    assert_equal false, @world.hold?
  end

  def test_per_badge_brake_revokes_nobody_when_too_many_would_go
    ids = (1..10).to_a
    users = ids.map { |i| user(i, "0x#{i.to_s(16).rjust(2, '0') * 20}") }
    @world.user_badges[@badge].merge(ids)
    holdings = users.each_with_object({}) { |u, h| h[u[:addresses].first] = { 13 => 0 } }
    cfg = { floor: 3, percent: 20, confirmations: 1 }
    report = run_mirror(users, holdings, config: cfg)
    assert_equal ids, usernames_of(@world, @badge)
    assert_equal true, report[:badges]['13'][:braked]
    assert_equal true, @world.hold?
  end

  def test_under_the_brake_the_revokes_go_through
    ids = (1..10).to_a
    users = ids.map { |i| user(i, "0x#{i.to_s(16).rjust(2, '0') * 20}") }
    @world.user_badges[@badge].merge(ids)
    holdings = users.each_with_object({}) { |u, h| h[u[:addresses].first] = { 13 => u[:id] <= 8 ? 1 : 0 } }
    run_mirror(users, holdings, config: { floor: 3, percent: 20, confirmations: 1 })
    assert_equal (1..8).to_a, usernames_of(@world, @badge)
  end

  def test_global_brake_catches_many_small_badges_losing_holders_at_once
    # three badges, each with two holders: every per-badge count is under the
    # floor, the total is not
    world = World.new
    rows = [row(13), row(14), row(15)]
    mirror(world, rows: rows).run(mode: 'enforce')
    users = (1..2).map { |i| user(i, "0x#{i.to_s(16).rjust(2, '0') * 20}") }
    world.records.each_value { |r| world.user_badges[r[:badge_id]].merge([1, 2]) }
    holdings = users.each_with_object({}) { |u, h| h[u[:addresses].first] = { 13 => 0, 14 => 0, 15 => 0 } }
    report = mirror(world, rows: rows, users: users, holdings: holdings, config: { floor: 4, percent: 20, confirmations: 1 }).run(mode: 'enforce')
    assert_equal true, report[:braked_global]
    assert_equal 6, world.user_badges.values.sum(&:size)
    assert_equal true, world.hold?
  end

  def test_a_clean_run_after_the_brake_applies_the_revokes_when_confirmed_and_within_limits
    @world.user_badges[@badge].merge([1, 2])
    users = [user(1, A), user(2, B)]
    run_mirror(users, { A => { 13 => 0 }, B => { 13 => 1 } }, config: { floor: 3, confirmations: 1 })
    assert_equal [2], usernames_of(@world, @badge)
  end

  def test_duplicates_sharing_an_address_go_to_the_oldest_account_only
    users = [user(9, A, B), user(4, B, C), user(2, D)] # 9 and 4 share B
    report = run_mirror(users, B => { 13 => 1 }, D => { 13 => 1 })
    assert_equal [2, 4], usernames_of(@world, @badge)
    assert_equal [{ skipped: 'user9', kept: 'user4' }], report[:duplicates_skipped]
  end

  def test_dedupe_is_stable_when_the_wallet_flips_between_s_and_e
    before = Mirror.dedupe([user(9, A, B), user(4, B, C)])
    after = Mirror.dedupe([user(4, B, C), user(9, B, A)])
    assert_equal [4], before[:winners].map { |u| u[:id] }
    assert_equal before[:skipped], after[:skipped]
  end

  def test_dedupe_chains_through_shared_addresses
    result = Mirror.dedupe([user(5, A), user(3, A, B), user(8, B), user(1, D)])
    assert_equal [1, 3], result[:winners].map { |u| u[:id] }
    assert_equal({ 5 => 3, 8 => 3 }, result[:skipped])
  end

  # E is an EOA, S the Light Account that E owns. After the rewrite the old row
  # (4) has E, the new row (9) has S and owner E, so they are one person.
  def test_a_badge_held_only_on_the_duplicates_light_account_address_counts_for_the_person
    users = [user(9, S, E), user(4, E)] # 4 wins; its own address list says only E
    run_mirror(users, S => { 13 => 1 }, E => { 13 => 0 })
    assert_equal [4], usernames_of(@world, @badge)
  end

  def test_the_badge_is_not_revoked_from_either_account_just_because_the_winners_own_address_is_empty
    @world.user_badges[@badge].merge([9]) # migrated E -> S, the badge sits on 9
    users = [user(9, S, E), user(4, E)]
    3.times { run_mirror(users, { S => { 13 => 1 }, E => { 13 => 0 } }, config: { confirmations: 1, floor: 5 }) }
    assert_equal [4], usernames_of(@world, @badge) # the person has it, once, on the oldest account
    assert_equal [[@badge, 9]], @world.revokes_log, 'only the duplicate loses it, and only because the person holds it'
  end

  def test_a_stale_or_missing_address_map_still_finds_the_holding_through_the_shared_address
    # No map pairing S with E: row 9 only knows S and its owner E, row 4 only E.
    users = [user(4, E), user(9, S, E), user(2, D)]
    run_mirror(users, S => { 13 => 2 }, D => { 13 => 1 })
    assert_equal [2, 4], usernames_of(@world, @badge)
  end

  def test_a_shared_owner_address_links_accounts_even_when_the_holding_is_on_it
    run_mirror([user(9, S, E), user(4, E)], E => { 13 => 1 })
    assert_equal [4], usernames_of(@world, @badge)
  end

  def test_a_duplicates_badge_is_kept_when_the_persons_holdings_cannot_be_read
    @world.user_badges[@badge].merge([4, 9])
    users = [user(9, S, E), user(4, E)]
    # E reads zero, S cannot be read: the person is unknown, so neither account is touched.
    holdings = ->(addresses, _ids) { addresses.each_with_object({}) { |a, h| h[a] = a == S ? { 13 => nil } : { 13 => 0 } } }
    ownership_with_other_member = lambda do |addresses, ids|
      holdings.call(addresses, ids).merge(D => { 13 => 1 })
    end
    4.times { run_mirror(users + [user(2, D)], {}, ownership: ownership_with_other_member, config: { confirmations: 1, floor: 5 }) }
    assert_equal [2, 4, 9], usernames_of(@world, @badge)
    assert_empty @world.revokes_log
  end

  def test_a_duplicate_is_revoked_only_when_the_whole_group_reads_absent_and_is_confirmed
    @world.user_badges[@badge].merge([4, 9])
    users = [user(9, S, E), user(4, E)]
    run_mirror(users, { S => { 13 => 0 }, E => { 13 => 0 } }, config: { confirmations: 2, floor: 5 })
    assert_equal [4, 9], usernames_of(@world, @badge)
    run_mirror(users, { S => { 13 => 0 }, E => { 13 => 0 } }, config: { confirmations: 2, floor: 5 })
    assert_empty usernames_of(@world, @badge)
  end

  def test_dedupe_carries_the_union_of_the_groups_addresses_on_the_winner
    result = Mirror.dedupe([user(9, S, E), user(4, E), user(1, D)])
    winner = result[:winners].find { |u| u[:id] == 4 }
    assert_equal [E, S].sort, winner[:addresses].sort
    assert_equal [D], result[:winners].find { |u| u[:id] == 1 }[:addresses]
    assert_equal({ 9 => 4 }, result[:skipped])
  end

  def test_a_duplicate_that_holds_a_badge_loses_it_after_confirmation
    @world.user_badges[@badge].merge([4, 9])
    users = [user(9, A, B), user(4, B, C)]
    2.times { run_mirror(users, { B => { 13 => 1 } }, config: { confirmations: 2, floor: 3 }) }
    assert_equal [4], usernames_of(@world, @badge)
  end

  def test_notifications_are_suppressed_until_the_badge_has_been_backfilled
    run_mirror([user(1, A)], A => { 13 => 1 })
    assert_equal [[@badge, 1, true]], @world.grants_log
    assert @world.records[13][:backfilled]
    run_mirror([user(1, A), user(2, B)], A => { 13 => 1 }, B => { 13 => 1 })
    assert_equal [@badge, 2, false], @world.grants_log.last
  end

  def test_notifications_can_be_switched_off
    run_mirror([user(1, A)], { A => { 13 => 1 } })
    run_mirror([user(1, A), user(2, B)], { A => { 13 => 1 }, B => { 13 => 1 } }, config: { notify: false })
    assert_equal [@badge, 2, true], @world.grants_log.last
  end

  def test_a_refused_grant_is_reported
    @world.grant_result = nil
    report = run_mirror([user(1, A)], A => { 13 => 1 })
    assert_equal :errors, report[:status]
    assert_match(/refused/, report[:errors].first)
  end

  def test_archived_badges_are_not_reconciled
    @world.records[13] = @world.records[13].merge(archived: true)
    @world.user_badges[@badge] << 1
    3.times { run_mirror([user(1, A)], { A => { 13 => 0 } }, catalog: :none) }
    assert_equal [1], usernames_of(@world, @badge)
  end

  def test_only_mirrored_token_ids_are_ever_requested_from_the_chain
    asked = nil
    spy = lambda do |addresses, ids|
      asked = ids
      addresses.each_with_object({}) { |a, h| h[a] = {} }
    end
    run_mirror([user(1, A)], {}, ownership: spy)
    assert_equal [13], asked
  end
end

class MirrorLogModeTest < Minitest::Test
  include MirrorHelpers

  def test_log_mode_reads_and_reports_but_writes_nothing
    world = World.new
    mirror(world).run(mode: 'enforce')
    badge = world.records[13][:badge_id]
    world.user_badges[badge] << 1
    world.writes.clear
    rows = [row(13, 'metadata' => { 'description' => 'changed', 'imageUrl' => 'https://cdn.example.com/n.png' }), row(14)]
    users = [user(1, A), user(2, B)]
    report = mirror(world, rows: rows, users: users, holdings: { A => { 13 => 0, 14 => 0 }, B => { 13 => 1, 14 => 1 } })
             .run(mode: 'log')

    assert_empty world.writes, "log mode wrote: #{world.writes.inspect}"
    assert_equal [14], report[:catalog][:created]
    assert_equal [13], report[:catalog][:updated]
    assert_equal ['user2'], report[:badges]['13'][:add]
    assert_equal ['user2'], report[:badges]['14'][:add]
    assert_equal [1], usernames_of(world, badge)
  end

  def test_log_mode_on_an_empty_forum_reports_would_be_grants_without_touching_anything
    world = World.new
    report = mirror(world, users: [user(1, A)], holdings: { A => { 13 => 1 } }).run(mode: 'log')
    assert_empty world.writes
    assert_equal [13], report[:catalog][:created]
    assert_equal ['user1'], report[:badges]['13'][:add]
  end

  def test_unknown_mode_is_rejected
    assert_raises(ArgumentError) { mirror(World.new).run(mode: 'off') }
  end
end

class MirrorUserRunTest < Minitest::Test
  include MirrorHelpers

  def setup
    @world = World.new
    mirror(@world).run(mode: 'enforce')
    @badge = @world.records[13][:badge_id]
    @world.records[13] = @world.records[13].merge(backfilled: true)
  end

  def user_run(users, holdings, ids, **opts)
    mirror(@world, users: users, holdings: holdings, catalog: :none, **opts).run(mode: 'enforce', user_ids: ids)
  end

  def test_grants_and_never_touches_other_members
    @world.user_badges[@badge] << 2
    user_run([user(1, A), user(2, B)], { A => { 13 => 1 }, B => { 13 => 0 } }, [1], config: { confirmations: 1 })
    assert_equal [1, 2], usernames_of(@world, @badge)
  end

  def test_a_login_run_never_revokes_however_often_it_runs
    @world.user_badges[@badge].merge([1, 2])
    users = [user(1, A), user(2, B)]
    holdings = { A => { 13 => 0 }, B => { 13 => 0 } }
    5.times { user_run(users, holdings, [1], config: { confirmations: 1 }) }
    assert_equal [1, 2], usernames_of(@world, @badge)
    assert_empty @world.revokes_log
  end

  def test_login_runs_cannot_complete_a_confirmation_the_full_run_started
    # Full run #1 saw user 1 absent once (e.g. a lagging RPC returning zeros).
    @world.user_badges[@badge].merge([1, 2])
    users = [user(1, A), user(2, B)]
    holdings = { A => { 13 => 0 }, B => { 13 => 1 } }
    mirror(@world, users: users, holdings: holdings).run(mode: 'enforce')
    assert_equal({ 1 => 1 }, @world.pending['13'])
    # User 1 logs in before the next hourly run: still not revoked.
    user_run(users, holdings, [1])
    assert_equal [1, 2], usernames_of(@world, @badge)
    assert_equal({ 1 => 1 }, @world.pending['13'], 'the login run did not advance the counter')
  end

  def test_a_login_run_persists_nothing_but_grants
    strict = World.new
    mirror(strict).run(mode: 'enforce')
    badge = strict.records[13][:badge_id]
    strict.records[13] = strict.records[13].merge(backfilled: true)
    strict.pending.replace('13' => { 2 => 1 })
    strict.hold = true
    strict.user_badges[badge].merge([2])
    strict.writes.clear
    spy = strict.store
    %i[pending hold? save_pending set_hold save_record save_meta].each do |name|
      spy.define_singleton_method(name) { |*_args| raise "a login run must not use store.#{name}" }
    end
    report = Mirror.new(
      store: spy, badges: strict, grants: strict, ownership: ->(addresses, _ids) { addresses.each_with_object({}) { |a, h| h[a] = { 13 => (a == A ? 1 : 0) } } },
      users: [user(1, A), user(2, B)], config: Mirror.config, now: -> { NOW },
    ).run(mode: 'enforce', user_ids: [1])
    assert_equal :ok, report[:status]
    assert_equal [[:grant, badge, 1]], strict.writes
    assert_equal({ '13' => { 2 => 1 } }, strict.pending)
    assert_equal true, strict.hold?
  end

  def test_a_hold_does_not_stop_a_login_grant
    @world.hold = true
    user_run([user(1, A)], { A => { 13 => 1 } }, [1])
    assert_equal [1], usernames_of(@world, @badge)
  end

  def test_a_login_run_on_a_duplicate_account_is_judged_by_the_whole_group
    users = [user(4, E), user(9, S, E)]
    user_run(users, { S => { 13 => 1 }, E => { 13 => 0 } }, [9])
    assert_empty usernames_of(@world, @badge), 'the duplicate itself never gets the badge'
    user_run(users, { S => { 13 => 1 }, E => { 13 => 0 } }, [4])
    assert_equal [4], usernames_of(@world, @badge), 'the oldest account does, from the duplicates holding'
  end

  def test_a_login_run_after_a_failed_full_run_still_only_adds
    @world.hold = true
    @world.user_badges[@badge].merge([1, 2])
    3.times { user_run([user(1, A), user(2, B)], { A => { 13 => 0 }, B => { 13 => 0 } }, [1], config: { confirmations: 1 }) }
    assert_equal [1, 2], usernames_of(@world, @badge)
  end

  def test_a_login_run_does_not_wipe_other_members_counters_or_the_hold
    @world.hold = true
    @world.pending.replace('13' => { 2 => 1 })
    user_run([user(1, A), user(2, B)], { A => { 13 => 1 } }, [1])
    assert_equal true, @world.hold?
    assert_equal({ '13' => { 2 => 1 } }, @world.pending)
    @world.hold = false
    @world.user_badges[@badge].merge([1, 2])
    user_run([user(1, A), user(2, B)], { A => { 13 => 1 }, B => { 13 => 0 } }, [1])
    assert_equal({ '13' => { 2 => 1 } }, @world.pending)
  end

  def test_an_ineligible_user_is_a_no_op
    report = user_run([user(1, A)], { A => { 13 => 1 } }, [99])
    assert_equal({}, report[:badges])
    assert_empty @world.grants_log
  end

  def test_debounce
    assert Mirror.login_due?(nil, NOW)
    refute Mirror.login_due?(NOW.to_i - 600, NOW)
    assert Mirror.login_due?(NOW.to_i - 3600, NOW)
    assert Mirror.login_due?((NOW - 7200).to_i.to_s, NOW)
  end
end
