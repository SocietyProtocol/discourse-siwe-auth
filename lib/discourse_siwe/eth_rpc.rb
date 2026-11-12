# frozen_string_literal: true

require 'net/http'
require 'json'
require 'digest/keccak'

module DiscourseSiwe
  # Reusable Ethereum JSON-RPC helpers used by the SIWE strategy, ENS resolver,
  # Society Protocol resolver, and the migration rake task.
  module EthRpc
    module_function

    def rpc_url
      url = SiteSetting.siwe_ethereum_rpc_url rescue nil
      url if url&.present?
    end

    def connection
      uri = URI(rpc_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 10
      http.read_timeout = 10
      http
    end

    # Raised by the strict helpers below. Unlike eth_call, which turns
    # every failure into nil, these never let an RPC failure look like an
    # answer. Messages never contain the URL (it carries the API key).
    Error = Class.new(StandardError)

    # RPC used for badge reads. A separate setting because staging reads
    # Sepolia badges while SIWE verification stays on mainnet.
    def badges_rpc_url
      url = SiteSetting.siwe_society_badges_rpc_url.to_s.strip rescue ''
      url.empty? ? rpc_url : url
    end

    # One JSON-RPC request. Returns the "result" member or raises Error.
    def rpc_request(url, method, params, timeout: 10)
      raise Error, 'RPC URL is not configured' if url.to_s.strip.empty?

      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = timeout
      http.read_timeout = timeout

      req = Net::HTTP::Post.new(uri.request_uri, 'Content-Type' => 'application/json')
      req.body = { jsonrpc: '2.0', method: method, params: params, id: 1 }.to_json

      response = http.request(req)
      raise Error, "RPC HTTP #{response.code}" unless response.code == '200'

      body = JSON.parse(response.body)
      raise Error, "RPC error: #{body['error']['message'].to_s[0, 120]}" if body.is_a?(Hash) && body['error']
      raise Error, 'RPC returned no result' unless body.is_a?(Hash) && body.key?('result')

      body['result']
    rescue Error
      raise
    rescue StandardError => e
      raise Error, "RPC request failed (#{e.class})"
    end

    # eth_call that raises on any failure (including a revert). Returns the
    # result hex without 0x ('' for an empty result).
    def eth_call_strict(to, data, url:, block: 'latest')
      result = rpc_request(url, 'eth_call', [{ to: to, data: data }, block])
      raise Error, 'eth_call returned a non-string result' unless result.is_a?(String)

      remove_hex_prefix(result)
    end

    def chain_id(url:)
      result = rpc_request(url, 'eth_chainId', [])
      raise Error, 'eth_chainId returned a non-string result' unless result.is_a?(String)

      remove_hex_prefix(result).to_i(16)
    end

    # Code hex without 0x ('' for an EOA); raises when the RPC fails.
    def get_code_strict(address, url:)
      result = rpc_request(url, 'eth_getCode', [address, 'latest'])
      raise Error, 'eth_getCode returned a non-string result' unless result.is_a?(String)

      remove_hex_prefix(result)
    end

    # ABI tail of a dynamic uint256[]: length word, then the elements.
    def encode_uint256_list(values)
      encode_uint256(values.size) + values.map { |v| encode_uint256(v) }.join
    end

    # ABI tail of a dynamic address[].
    def encode_address_list(addresses)
      encode_uint256(addresses.size) + addresses.map { |a| encode_address(a) }.join
    end

    # Decodes a returned uint256[] (offset word, length word, elements).
    # Raises Error on anything malformed or truncated instead of guessing.
    def decode_uint256_list(hex)
      hex = hex.to_s
      raise Error, 'empty array result' if hex.length < 128

      offset = hex[0, 64].to_i(16) * 2
      length = hex[offset, 64].to_s.to_i(16)
      start = offset + 64
      raise Error, 'truncated array result' if hex.length < start + length * 64

      Array.new(length) { |i| hex[start + i * 64, 64].to_i(16) }
    end

    # Generic eth_call. Returns hex result without 0x prefix, or nil.
    # `to` may be nil for contract-creation simulation (used by EIP-6492).
    def eth_call(to, data, http: nil)
      return nil unless rpc_url

      http ||= connection
      path = URI(rpc_url).path
      path = '/' if path.empty?

      req = Net::HTTP::Post.new(path, 'Content-Type' => 'application/json')
      call_params = { data: data }
      call_params[:to] = to if to
      req.body = {
        jsonrpc: '2.0',
        method: 'eth_call',
        params: [call_params, 'latest'],
        id: 1
      }.to_json

      response = http.request(req)
      result = JSON.parse(response.body)
      return nil if result['error'] || result['result'].nil? || result['result'] == '0x'

      remove_hex_prefix(result['result'])
    rescue StandardError
      nil
    end

    def encode_address(addr)
      remove_hex_prefix(addr).downcase.rjust(64, '0')
    end

    def encode_uint256(n)
      n.to_i.to_s(16).rjust(64, '0')
    end

    def decode_address(hex)
      return nil if hex.nil? || hex.length < 40
      address = hex[-40, 40]
      return nil if address == '0' * 40
      "0x#{address}"
    end

    def decode_uint256(hex)
      return nil if hex.nil? || hex.empty?
      hex.to_i(16)
    end

    def decode_string(hex)
      return nil if hex.nil? || hex.length < 128
      offset = hex[0, 64].to_i(16) * 2
      length = hex[offset, 64].to_i(16)
      return '' if length.zero?
      data_start = offset + 64
      return nil if hex.length < data_start + length * 2
      [hex[data_start, length * 2]].pack('H*').force_encoding('UTF-8')
    end

    # Keccak-256 via the keccak gem (no native rbsecp256k1 dependency).
    def keccak256(data)
      Digest::Keccak.new(256).digest(data)
    end

    def bin_to_hex(bin)
      bin.unpack1('H*')
    end

    def remove_hex_prefix(str)
      str.to_s.sub(/\A0x/i, '')
    end
  end
end
