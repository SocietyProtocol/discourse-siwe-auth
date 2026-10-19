# frozen_string_literal: true

module DiscourseSiwe
  # Alchemy Light Account v2 helpers, ported from web3-app-client
  # src/lib/smart-account.ts. The forum identity is the Light Account S that
  # the connected EOA owns:
  #   S = LightAccountFactory.getAddress(owner, 0)
  # Pure functions over EthRpc.keccak256; no RPC.
  module LightAccount
    module_function

    FACTORY        = '0x0000000000400CdFef5E2714E63d8040b700BC24'
    IMPLEMENTATION = '0x8E8e658E22B12ada97B402fF0b044D6A325013C7'
    SALT = 0

    EIP6492_MAGIC = '6492649264926492649264926492649264926492649264926492649264926492'

    # createAccount(address,uint256)
    CREATE_ACCOUNT_SELECTOR = EthRpc.bin_to_hex(
      EthRpc.keccak256('createAccount(address,uint256)')[0, 4]
    ).freeze

    ADDRESS_RE = /\A0x[0-9a-fA-F]{40}\z/.freeze

    # Solady ERC-1967 proxy init code the factory deploys (LibClone
    # deployERC1967 layout, flattened from lightAccountInitCode).
    def init_code(implementation = IMPLEMENTATION)
      '603d3d8160223d3973' +
        EthRpc.remove_hex_prefix(implementation).downcase +
        '6009' \
        '5155f3363d3d373d3d363d7f360894a13ba1a3210667c828492db98dca3e2076' \
        'cc3735a920a3ca505d382bbc545af43d6000803e6038573d6000fd5b3d6000f3'
    end

    # Code left at a deployed S: init code minus its 34-byte constructor prefix.
    def proxy_runtime_code
      init_code[34 * 2..-1]
    end

    def init_code_hash
      @init_code_hash ||= EthRpc.keccak256([init_code].pack('H*'))
    end

    def address(owner)
      raise ArgumentError, "invalid owner address: #{owner.inspect}" unless valid_address?(owner)

      salt = EthRpc.keccak256(
        [EthRpc.encode_address(owner) + EthRpc.encode_uint256(SALT)].pack('H*')
      )
      factory = [EthRpc.remove_hex_prefix(FACTORY)].pack('H*')
      digest = EthRpc.keccak256("\xff".b + factory + salt + init_code_hash)
      checksum("0x#{EthRpc.bin_to_hex(digest[12, 20])}")
    end

    # EIP-55 mixed-case checksum. Same output as Eth::Address#checksummed.
    def checksum(addr)
      raise ArgumentError, "invalid address: #{addr.inspect}" unless valid_address?(addr)

      hex = EthRpc.remove_hex_prefix(addr).downcase
      hash = EthRpc.bin_to_hex(EthRpc.keccak256(hex))
      '0x' + hex.chars.each_with_index.map { |c, i| hash[i].to_i(16) >= 8 ? c.upcase : c }.join
    end

    def valid_address?(addr)
      addr.is_a?(String) && addr.match?(ADDRESS_RE)
    end

    def same_address?(a, b)
      valid_address?(a) && valid_address?(b) && a.downcase == b.downcase
    end

    # Owner EOA of `account`, read from an EIP-6492 wrapped signature whose
    # factory call is createAccount(owner, 0) on FACTORY. Returns the
    # checksummed owner only when CREATE2 binds it to `account`, else nil.
    def owner_from_signature(account, signature)
      sig = EthRpc.remove_hex_prefix(signature).downcase
      return nil unless sig.end_with?(EIP6492_MAGIC)

      body = sig[0...-EIP6492_MAGIC.length]
      factory = EthRpc.decode_address(body[0, 64])
      return nil unless same_address?(factory, FACTORY)

      data = abi_bytes(body, body[64, 64].to_i(16))
      return nil unless data && data.length == 8 + 64 * 2
      return nil unless data[0, 8] == CREATE_ACCOUNT_SELECTOR
      return nil unless data[8 + 64, 64].to_i(16) == SALT

      owner = EthRpc.decode_address(data[8, 64])
      return nil unless owner && same_address?(address(owner), account)

      checksum(owner)
    rescue ArgumentError
      nil
    end

    # Dynamic `bytes` at byte `offset` in ABI-encoded hex.
    def abi_bytes(hex, offset)
      start = offset * 2
      return nil if hex.length < start + 64

      length = hex[start, 64].to_i(16) * 2
      return nil if hex.length < start + 64 + length

      hex[start + 64, length]
    end
  end
end
