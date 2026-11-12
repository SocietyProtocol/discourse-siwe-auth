# frozen_string_literal: true

require 'net/http'
require 'json'

module DiscourseSiwe
  # Resolves a Society Protocol profile badge for an Ethereum address.
  # Uses the configured subgraph by default and falls back to direct RPC calls.
  # Every failure path returns nil so login is never blocked.
  class IdentityResolver
    # Standard ERC-1155 selectors.
    BALANCE_OF_SELECTOR = '00fdd58e'
    URI_SELECTOR        = '0e89341c'

    # SocietyProtocolBadges.profileBadgeId(address)
    PROFILE_BADGE_ID_SELECTOR = EthRpc.bin_to_hex(
      EthRpc.keccak256('profileBadgeId(address)')[0, 4]
    ).freeze

    # The production query gateway only runs persisted documents, matched by
    # operation name and by the exact canonical text. This is the registered
    # `User` document (web3-app-subgraph infra/query-gateway/generated/
    # registry.js); change it only together with the registry.
    USER_OPERATION = 'User'
    USER_QUERY = <<~GRAPHQL
      query User($id: ID!) {
        user(id: $id) {
          id
          name
          bio
          imageUrl
          metadata {
            name
            bio
            imageUrl
          }
          communities(first: 1000) {
            id
          }
          profile {
            id
          }
          invitedBy {
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
          badges(first: 1000, where: {isProfile: false}) {
            id
            name
            description
            isOfficial
            isCommunity
            uri
            hookAddress
            imageUrl
            metadata {
              description
              imageUrl
            }
            creatorAddress
            createdAt
            holdersCount
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
          managedBadges(first: 1000, where: {isProfile: false}) {
            id
            name
            description
            isOfficial
            isCommunity
            uri
            hookAddress
            imageUrl
            metadata {
              description
              imageUrl
            }
            creatorAddress
            createdAt
            holdersCount
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
      }
    GRAPHQL

    # Returned instead of nil when a lookup could not be completed (network
    # error, gateway rejection, bad response). nil means "looked it up and
    # there is no profile"; this means "unknown, change nothing".
    LOOKUP_FAILED = :lookup_failed
    FILEBASE_GATEWAY = 'https://ipfs.filebase.io/ipfs/'

    def self.resolve(wallet_address)
      new(wallet_address).resolve
    end

    def initialize(wallet_address)
      @wallet_address = wallet_address.to_s.downcase
    end

    # Returns { badge_id:, name:, bio:, avatar:, uri: }, nil when the address
    # has no Society profile, or LOOKUP_FAILED when it could not be determined.
    def resolve
      return nil unless SiteSetting.siwe_society_enabled
      return nil unless @wallet_address.match?(/\A0x[0-9a-fA-F]{40}\z/)

      if SiteSetting.siwe_identity_resolution_mode == 'subgraph' &&
         !SiteSetting.siwe_society_subgraph_url.to_s.strip.empty?
        subgraph = via_subgraph
        return subgraph if subgraph.is_a?(Hash) || subgraph.nil?

        # Subgraph failed: try the chain, but keep "unknown" if that is empty.
        via_rpc || LOOKUP_FAILED
      else
        via_rpc
      end
    end

    private

    # Hash (profile), nil (no such user / no profile), or LOOKUP_FAILED.
    def via_subgraph
      uri = URI(SiteSetting.siwe_society_subgraph_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 10
      http.read_timeout = 10

      headers = { 'Content-Type' => 'application/json' }
      token = subgraph_token
      headers['Authorization'] = "Bearer #{token}" unless token.empty?

      req = Net::HTTP::Post.new(uri.path.empty? ? '/' : uri.path, headers)
      req.body = {
        query: USER_QUERY,
        operationName: USER_OPERATION,
        variables: { id: @wallet_address },
      }.to_json

      response = http.request(req)
      unless response.code.to_i == 200
        log_warn("[discourse-siwe-auth] Society subgraph HTTP #{response.code}")
        return LOOKUP_FAILED
      end

      body = JSON.parse(response.body)
      if body['errors'].is_a?(Array) && !body['errors'].empty?
        log_warn("[discourse-siwe-auth] Society subgraph error: #{body['errors'].first.inspect}")
        return LOOKUP_FAILED
      end
      return LOOKUP_FAILED unless body.is_a?(Hash) && body.key?('data')

      data = body.dig('data', 'user')
      return nil unless data

      profile = data['profile'] || {}
      metadata = data['metadata'] || {}
      {
        badge_id: profile['id'],
        name:   first_non_empty(data['name'], metadata['name']),
        bio:    first_non_empty(data['bio'], metadata['bio']),
        avatar: normalize_url(
          first_non_empty(data['imageUrl'], metadata['imageUrl'])
        ),
        uri:    nil,
      }
    rescue StandardError => e
      log_warn("[discourse-siwe-auth] Society subgraph error: #{e.message}")
      LOOKUP_FAILED
    end

    def subgraph_token
      value = SiteSetting.respond_to?(:siwe_society_subgraph_token) ? SiteSetting.siwe_society_subgraph_token : ''
      value.to_s.strip
    end

    def via_rpc
      return nil unless DiscourseSiwe::EthRpc.rpc_url
      contract = SiteSetting.siwe_society_badges_contract.to_s
      return nil unless contract.match?(/\A0x[0-9a-fA-F]{40}\z/)

      http = DiscourseSiwe::EthRpc.connection
      http.start do
        badge_id_hex = DiscourseSiwe::EthRpc.eth_call(
          contract,
          "0x#{PROFILE_BADGE_ID_SELECTOR}#{DiscourseSiwe::EthRpc.encode_address(@wallet_address)}",
          http: http
        )
        badge_id = DiscourseSiwe::EthRpc.decode_uint256(badge_id_hex)
        return nil if badge_id.nil? || badge_id.zero?

        balance_hex = DiscourseSiwe::EthRpc.eth_call(
          contract,
          "0x#{BALANCE_OF_SELECTOR}" \
            "#{DiscourseSiwe::EthRpc.encode_address(@wallet_address)}" \
            "#{DiscourseSiwe::EthRpc.encode_uint256(badge_id)}",
          http: http
        )
        balance = DiscourseSiwe::EthRpc.decode_uint256(balance_hex)
        return nil if balance.nil? || balance.zero?

        uri_hex = DiscourseSiwe::EthRpc.eth_call(
          contract,
          "0x#{URI_SELECTOR}#{DiscourseSiwe::EthRpc.encode_uint256(badge_id)}",
          http: http
        )
        metadata_uri = DiscourseSiwe::EthRpc.decode_string(uri_hex)
        meta = fetch_metadata(metadata_uri)

        {
          badge_id: badge_id.to_s,
          name:   first_non_empty(meta&.dig('name')),
          bio:    first_non_empty(meta&.dig('bio'), meta&.dig('description')),
          avatar: normalize_url(
            first_non_empty(meta&.dig('imageUrl'), meta&.dig('image'))
          ),
          uri:    metadata_uri,
        }
      end
    rescue StandardError => e
      log_warn("[discourse-siwe-auth] Society RPC resolution error: #{e.message}")
      LOOKUP_FAILED
    end

    def fetch_metadata(metadata_uri)
      url = normalize_url(metadata_uri)
      return nil if url.to_s.strip.empty?

      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 10
      http.read_timeout = 10
      JSON.parse(http.request(Net::HTTP::Get.new(uri.request_uri)).body)
    rescue StandardError
      nil
    end

    def normalize_url(url)
      value = url.to_s.strip
      return nil if value.empty?
      return nil if value.start_with?('data:')

      if value.start_with?('ipfs://')
        value = "#{FILEBASE_GATEWAY}#{value.delete_prefix('ipfs://')}"
      end
      match = value.match(%r{/ipfs/([^/?#]+)})
      return "#{FILEBASE_GATEWAY}#{match[1]}" if match

      value
    end

    def first_non_empty(*values)
      values.find { |v| !v.to_s.strip.empty? }
    end

    def log_warn(message)
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.warn(message)
      end
    end
  end
end
