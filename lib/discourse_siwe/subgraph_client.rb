# frozen_string_literal: true

require 'net/http'
require 'json'

module DiscourseSiwe
  # Minimal client for the Society query gateway.
  #
  # The production gateway only runs persisted documents: the request must
  # carry the exact printed query text of a registered operation, its
  # operation name, and a bearer token. This client sends whatever document it
  # is given (the caller owns the exact text, see BadgeCatalogSource) and
  # never returns a partial answer: any transport, HTTP, GraphQL or shape
  # problem raises Error, so "could not ask" can never be mistaken for "the
  # answer is empty".
  #
  # Messages never contain the URL or the token.
  #
  # IdentityResolver keeps its own request code on purpose: it predates this
  # client and has a different failure contract (LOOKUP_FAILED), and changing
  # it was not worth the risk to the login path.
  class SubgraphClient
    Error = Class.new(StandardError)

    DEFAULT_TIMEOUT = 10

    # url, token: strings. http_factory: ->(uri) { object responding to
    # use_ssl=, open_timeout=, read_timeout=, request(req) } (tests inject one).
    def initialize(url:, token: '', timeout: DEFAULT_TIMEOUT, http_factory: nil)
      @url = url.to_s.strip
      @token = token.to_s.strip
      @timeout = timeout
      @http_factory = http_factory || ->(uri) { Net::HTTP.new(uri.host, uri.port) }
    end

    # Runs one persisted operation and returns its "data" hash.
    def query(operation:, document:, variables:)
      raise Error, 'subgraph URL is not configured' if @url.empty?

      uri = URI(@url)
      raise Error, 'subgraph URL must be http(s)' unless %w[http https].include?(uri.scheme)

      http = @http_factory.call(uri)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = @timeout
      http.read_timeout = @timeout

      headers = { 'Content-Type' => 'application/json' }
      headers['Authorization'] = "Bearer #{@token}" unless @token.empty?
      req = Net::HTTP::Post.new(uri.path.empty? ? '/' : uri.request_uri, headers)
      req.body = { query: document, operationName: operation, variables: variables }.to_json

      response = http.request(req)
      raise Error, "gateway HTTP #{response.code}" unless response.code.to_i == 200

      body = JSON.parse(response.body)
      raise Error, 'gateway returned a non-object body' unless body.is_a?(Hash)

      if body['errors'].is_a?(Array) && !body['errors'].empty?
        first = body['errors'].first
        message = first.is_a?(Hash) ? first['message'].to_s[0, 120] : 'unknown'
        raise Error, "gateway error: #{message}"
      end
      raise Error, 'gateway returned no data' unless body['data'].is_a?(Hash)

      body['data']
    rescue Error
      raise
    rescue JSON::ParserError
      raise Error, 'gateway returned invalid JSON'
    rescue StandardError => e
      # Network errors: keep the class, drop the message (it can hold the host).
      raise Error, "gateway request failed (#{e.class})"
    end

    # Pages through a list field until a short page. Raises Error if the
    # result would exceed max_pages (never returns a silently truncated list).
    # variables_for: ->(first, skip) { variables hash }; extract: ->(data) { Array }
    def paginate(operation:, document:, page_size:, max_pages: 10, variables_for:, extract:)
      rows = []
      max_pages.times do |page|
        data = query(operation: operation, document: document, variables: variables_for.call(page_size, page * page_size))
        batch = extract.call(data)
        raise Error, 'gateway returned an unexpected list shape' unless batch.is_a?(Array)

        rows.concat(batch)
        return rows if batch.size < page_size
      end
      raise Error, "catalog is larger than #{max_pages * page_size} rows; refusing a truncated read"
    end
  end
end
