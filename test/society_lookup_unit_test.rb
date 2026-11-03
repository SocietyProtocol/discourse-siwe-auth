#!/usr/bin/env ruby
# frozen_string_literal: true

# Unit tests for the Society profile lookup through the query gateway:
# registered document, bearer token, and the tri-state result (profile / no
# profile / lookup failed). No network or Discourse needed.
#
# Run: ruby test/society_lookup_unit_test.rb

require_relative 'support/pure_keccak'
require 'json'
require 'time'
require 'minitest/autorun'
require_relative '../lib/discourse_siwe/eth_rpc'
require_relative '../lib/discourse_siwe/identity_resolver'
require_relative '../lib/discourse_siwe/identity_store'

# Minimal SiteSetting stub so this runs outside Discourse.
module SiteSetting
  class << self
    attr_writer :token

    def siwe_society_enabled

      true

    end
    def siwe_identity_resolution_mode
      'subgraph'
    end
    def siwe_society_subgraph_url
      'http://prod-gateway:8080/graphql'
    end
    def siwe_society_badges_contract
      '0x2313C0cDdc233c92d16c2cfE17DF5fDCcE556763'
    end
    def siwe_society_subgraph_token
      (@token || '')
    end
    def siwe_ethereum_rpc_url
      ''
    end
  end
end

# Stands in for Net::HTTP: records requests and replies from a queue.
class FakeHttp
  Response = Struct.new(:code, :body)

  class << self
    attr_accessor :requests, :replies

    def reset(*replies)
      self.requests = []
      self.replies = replies
    end
  end

  attr_writer :use_ssl, :open_timeout, :read_timeout

  def request(req)
    self.class.requests << req
    reply = self.class.replies.shift
    raise reply if reply.is_a?(Exception)

    Response.new(reply[0].to_s, reply[1])
  end
end

module NetHttpStub
  def self.with
    original = Net::HTTP.method(:new)
    Net::HTTP.define_singleton_method(:new) { |*_args| FakeHttp.new }
    yield
  ensure
    Net::HTTP.define_singleton_method(:new, original)
  end
end

PROFILE_BODY = {
  data: { user: { id: '0xabc', name: 'Ada', bio: 'hi', imageUrl: 'ipfs://bafy', metadata: nil, profile: { id: '42' } } },
}.to_json

class SocietyLookupTest < Minitest::Test
  ADDR = '0x' + 'a' * 40
  OWNER = '0x' + 'b' * 40
  FAILED = DiscourseSiwe::IdentityResolver::LOOKUP_FAILED

  def setup
    SiteSetting.token = 'x' * 40
  end

  def resolve(*replies)
    FakeHttp.reset(*replies)
    NetHttpStub.with { yield }
  end

  def test_query_is_the_registered_user_document
    assert_equal 'User', DiscourseSiwe::IdentityResolver::USER_OPERATION
    assert_match(/\Aquery User\(\$id: ID!\) \{/, DiscourseSiwe::IdentityResolver::USER_QUERY)
  end

  def test_sends_bearer_token_and_operation_name
    resolve([200, PROFILE_BODY]) do
      DiscourseSiwe::IdentityResolver.resolve(ADDR)
    end
    req = FakeHttp.requests.first
    assert_equal "Bearer #{'x' * 40}", req['Authorization']
    body = JSON.parse(req.body)
    assert_equal 'User', body['operationName']
    assert_equal ADDR, body['variables']['id']
  end

  def test_omits_authorization_without_a_token
    SiteSetting.token = ''
    resolve([200, PROFILE_BODY]) { DiscourseSiwe::IdentityResolver.resolve(ADDR) }
    assert_nil FakeHttp.requests.first['Authorization']
  end

  def test_returns_the_profile
    society = resolve([200, PROFILE_BODY]) { DiscourseSiwe::IdentityResolver.resolve(ADDR) }
    assert_equal '42', society[:badge_id]
    assert_equal 'Ada', society[:name]
    assert_equal 'https://ipfs.filebase.io/ipfs/bafy', society[:avatar]
  end

  def test_unknown_user_is_nil_not_a_failure
    society = resolve([200, { data: { user: nil } }.to_json]) { DiscourseSiwe::IdentityResolver.resolve(ADDR) }
    assert_nil society
  end

  def test_gateway_rejection_is_a_failure
    assert_equal FAILED, resolve([401, '{}']) { DiscourseSiwe::IdentityResolver.resolve(ADDR) }
    assert_equal FAILED, resolve([400, '{}']) { DiscourseSiwe::IdentityResolver.resolve(ADDR) }
  end

  def test_graphql_errors_are_a_failure
    body = { errors: [{ message: 'boom' }], data: nil }.to_json
    assert_equal FAILED, resolve([200, body]) { DiscourseSiwe::IdentityResolver.resolve(ADDR) }
  end

  def test_network_error_and_garbage_are_failures
    assert_equal FAILED, resolve(Errno::ECONNREFUSED.new) { DiscourseSiwe::IdentityResolver.resolve(ADDR) }
    assert_equal FAILED, resolve([200, 'not json']) { DiscourseSiwe::IdentityResolver.resolve(ADDR) }
  end

  def test_owner_profile_is_used_when_the_smart_account_has_none
    society = resolve([200, { data: { user: nil } }.to_json], [200, PROFILE_BODY]) do
      DiscourseSiwe::IdentityResolver.resolve_with_owner(ADDR, OWNER)
    end
    assert_equal 'Ada', society[:name]
    assert_equal 2, FakeHttp.requests.size
  end

  def test_no_profile_anywhere_is_nil
    empty = { data: { user: nil } }.to_json
    society = resolve([200, empty], [200, empty]) do
      DiscourseSiwe::IdentityResolver.resolve_with_owner(ADDR, OWNER)
    end
    assert_nil society
  end

  def test_a_failed_owner_lookup_is_not_reported_as_no_profile
    empty = { data: { user: nil } }.to_json
    society = resolve([200, empty], [503, '{}']) do
      DiscourseSiwe::IdentityResolver.resolve_with_owner(ADDR, OWNER)
    end
    assert_equal FAILED, society
  end
end

class StoreSocietyTest < Minitest::Test
  FAILED = DiscourseSiwe::IdentityResolver::LOOKUP_FAILED

  # A plain class rather than Struct: Ruby 3.2+ treats a trailing hash passed
  # to Struct.new as keywords, which broke this stub on the forum's Ruby 3.4.
  FakeUser = Class.new do
    attr_reader :custom_fields

    def initialize(fields)
      @custom_fields = fields
    end
  end

  def user
    FakeUser.new(
      'society_badge_id' => '42', 'society_name' => 'Ada', 'society_avatar' => 'https://a/b.png',
      'society_bio' => 'hi', 'society_resolved_at' => '2026-01-01T00:00:00Z',
    )
  end

  def test_failed_lookup_changes_nothing
    u = user
    refute DiscourseSiwe::IdentityStore.store_society(u, FAILED)
    assert_equal 'Ada', u.custom_fields['society_name']
    assert_equal '42', u.custom_fields['society_badge_id']
    assert_equal '2026-01-01T00:00:00Z', u.custom_fields['society_resolved_at']
  end

  def test_no_profile_clears_the_fields
    u = user
    assert DiscourseSiwe::IdentityStore.store_society(u, nil)
    assert_nil u.custom_fields['society_name']
    refute_equal '2026-01-01T00:00:00Z', u.custom_fields['society_resolved_at']
  end
end
