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

    # eth_getCode at `latest`. Returns code hex without 0x ('' for an EOA),
    # or nil when the RPC is unreachable. `url` overrides the site setting
    # (used by script/rewrite_smart_account_users.rb).
    def get_code(address, url: rpc_url)
      return nil unless url

      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = 10
      http.read_timeout = 10

      req = Net::HTTP::Post.new(uri.path.empty? ? '/' : uri.path, 'Content-Type' => 'application/json')
      req.body = {
        jsonrpc: '2.0',
        method: 'eth_getCode',
        params: [address, 'latest'],
        id: 1
      }.to_json

      result = JSON.parse(http.request(req).body)
      return nil if result['error'] || !result['result'].is_a?(String)

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
