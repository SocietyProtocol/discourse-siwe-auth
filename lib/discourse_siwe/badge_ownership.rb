# frozen_string_literal: true

module DiscourseSiwe
  # Reads ERC-1155 badge balances straight from the badges contract.
  #
  # The chain is the authority: the subgraph stores holding as a boolean and
  # cannot represent hooked badges (VIP), whose balanceOf is redirected to a
  # hook contract. A balance is an Integer, or nil when it could not be
  # determined. nil is never zero: callers must not treat "unknown" as "does
  # not hold".
  module BadgeOwnership
    class SourceError < StandardError; end

    BATCH_SIGNATURE = 'balanceOfBatch(address[],uint256[])'
    BALANCE_OF_SIGNATURE = 'balanceOf(address,uint256)'
    # balanceOfBatch is pairwise (accounts[i] with ids[i]), so a request of
    # N pairs carries N accounts and N ids.
    DEFAULT_CHUNK = 100
    MAX_CONSECUTIVE_FAILURES = 3

    module_function

    def selector(signature, rpc: EthRpc)
      rpc.bin_to_hex(rpc.keccak256(signature)[0, 4])
    end

    # Calldata for balanceOfBatch over equal-length account/id arrays.
    def batch_calldata(accounts, ids, rpc: EthRpc)
      raise ArgumentError, 'accounts and ids must be the same length' unless accounts.size == ids.size

      accounts_tail = rpc.encode_address_list(accounts)
      head = rpc.encode_uint256(64) + rpc.encode_uint256(64 + accounts_tail.length / 2)
      "0x#{selector(BATCH_SIGNATURE, rpc: rpc)}#{head}#{accounts_tail}#{rpc.encode_uint256_list(ids)}"
    end

    def balance_calldata(account, id, rpc: EthRpc)
      "0x#{selector(BALANCE_OF_SIGNATURE, rpc: rpc)}#{rpc.encode_address(account)}#{rpc.encode_uint256(id)}"
    end

    # addresses: lowercase 0x strings. badge_ids: Integers.
    # Returns { address => { badge_id => Integer | nil } }.
    # Raises SourceError when the chain or contract is not the expected one.
    def balances(addresses, badge_ids, contract:, url:, expected_chain_id: nil, chunk: DEFAULT_CHUNK, rpc: EthRpc)
      addresses = addresses.uniq
      badge_ids = badge_ids.uniq
      result = Hash.new { |h, k| h[k] = {} }
      return result if addresses.empty? || badge_ids.empty?

      preflight!(contract, url, expected_chain_id, rpc)

      pairs = addresses.product(badge_ids)
      consecutive_failures = 0
      pairs.each_slice(chunk) do |slice|
        values = batch(slice, contract, url, rpc)
        slice.each_with_index do |(address, id), index|
          # A reverting hook fails the whole batch; read that chunk pair by
          # pair so one bad badge cannot hide everyone else's balances.
          balance = values ? values[index] : single(address, id, contract, url, rpc)
          result[address][id] = balance
          next if values

          consecutive_failures = balance.nil? ? consecutive_failures + 1 : 0
          # A dead RPC would otherwise cost one timeout per pair.
          raise SourceError, 'RPC is failing on single reads too' if consecutive_failures >= MAX_CONSECUTIVE_FAILURES
        end
      end
      result
    end

    def preflight!(contract, url, expected_chain_id, rpc)
      if expected_chain_id && expected_chain_id.to_i.positive?
        actual = rpc.chain_id(url: url)
        raise SourceError, "wrong chain: RPC is #{actual}, expected #{expected_chain_id}" unless actual == expected_chain_id.to_i
      end
      raise SourceError, 'badges contract has no code on this chain' if rpc.get_code_strict(contract, url: url).empty?
    rescue EthRpc::Error => e
      raise SourceError, e.message
    end

    # Integer balances in request order, or nil if the batch call failed.
    def batch(slice, contract, url, rpc)
      data = batch_calldata(slice.map(&:first), slice.map(&:last), rpc: rpc)
      values = rpc.decode_uint256_list(rpc.eth_call_strict(contract, data, url: url))
      values.size == slice.size ? values : nil
    rescue EthRpc::Error
      nil
    end

    def single(address, id, contract, url, rpc)
      hex = rpc.eth_call_strict(contract, balance_calldata(address, id, rpc: rpc), url: url)
      hex.length >= 64 ? hex[0, 64].to_i(16) : nil
    rescue EthRpc::Error
      nil
    end
  end
end
