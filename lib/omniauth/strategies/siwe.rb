require 'net/http'
require 'json'

module OmniAuth
  module Strategies
    class Siwe
      include OmniAuth::Strategy

      # EIP-6492 universal signature validator bytecode (no 0x prefix).
      # Deployed via eth_call (no actual deployment) to verify EOA, ERC-1271,
      # and EIP-6492 signatures in a single call.
      # Constructor: (address signer, bytes32 hash, bytes signature)
      # Returns: 0x01 if valid, 0x00 if invalid
      # Source: EIP-6492 reference implementation
      EIP6492_VALIDATOR_BYTECODE = "608060405234801561001057600080fd5b5060405161069438038061069483398101604081905261002f9161051e565b600061003c848484610048565b9050806000526001601ff35b60007f64926492649264926492649264926492649264926492649264926492649264926100748361040c565b036101e7576000606080848060200190518101906100929190610577565b60405192955090935091506000906001600160a01b038516906100b69085906105dd565b6000604051808303816000865af19150503d80600081146100f3576040519150601f19603f3d011682016040523d82523d6000602084013e6100f8565b606091505b50509050876001600160a01b03163b60000361016057806101605760405162461bcd60e51b815260206004820152601e60248201527f5369676e617475726556616c696461746f723a206465706c6f796d656e74000060448201526064015b60405180910390fd5b604051630b135d3f60e11b808252906001600160a01b038a1690631626ba7e90610190908b9087906004016105f9565b602060405180830381865afa1580156101ad573d6000803e3d6000fd5b505050506040513d601f19601f820116820180604052508101906101d19190610633565b6001600160e01b03191614945050505050610405565b6001600160a01b0384163b1561027a57604051630b135d3f60e11b808252906001600160a01b03861690631626ba7e9061022790879087906004016105f9565b602060405180830381865afa158015610244573d6000803e3d6000fd5b505050506040513d601f19601f820116820180604052508101906102689190610633565b6001600160e01b031916149050610405565b81516041146102df5760405162461bcd60e51b815260206004820152603a602482015260008051602061067483398151915260448201527f3a20696e76616c6964207369676e6174757265206c656e6774680000000000006064820152608401610157565b6102e7610425565b5060208201516040808401518451859392600091859190811061030c5761030c61065d565b016020015160f81c9050601b811480159061032b57508060ff16601c14155b1561038c5760405162461bcd60e51b815260206004820152603b602482015260008051602061067483398151915260448201527f3a20696e76616c6964207369676e617475726520762076616c756500000000006064820152608401610157565b60408051600081526020810180835289905260ff83169181019190915260608101849052608081018390526001600160a01b0389169060019060a0016020604051602081039080840390855afa1580156103ea573d6000803e3d6000fd5b505050602060405103516001600160a01b0316149450505050505b9392505050565b600060208251101561041d57600080fd5b508051015190565b60405180606001604052806003906020820280368337509192915050565b6001600160a01b038116811461045857600080fd5b50565b634e487b7160e01b600052604160045260246000fd5b60005b8381101561048c578181015183820152602001610474565b50506000910152565b600082601f8301126104a657600080fd5b81516001600160401b038111156104bf576104bf61045b565b604051601f8201601f19908116603f011681016001600160401b03811182821017156104ed576104ed61045b565b60405281815283820160200185101561050557600080fd5b610516826020830160208701610471565b949350505050565b60008060006060848603121561053357600080fd5b835161053e81610443565b6020850151604086015191945092506001600160401b0381111561056157600080fd5b61056d86828701610495565b9150509250925092565b60008060006060848603121561058c57600080fd5b835161059781610443565b60208501519093506001600160401b038111156105b357600080fd5b6105bf86828701610495565b604086015190935090506001600160401b0381111561056157600080fd5b600082516105ef818460208701610471565b9190910192915050565b828152604060208201526000825180604084015261061e816060850160208701610471565b601f01601f1916919091016060019392505050565b60006020828403121561064557600080fd5b81516001600160e01b03198116811461040557600080fd5b634e487b7160e01b600052603260045260246000fdfe5369676e617475726556616c696461746f72237265636f7665725369676e6572"

      option :fields, %i[eth_message eth_signature]

      # Always EIP-55 checksummed: Discourse matches provider_uid exactly and
      # the forum rewrite stores checksummed addresses.
      uid do
        DiscourseSiwe::LightAccount.checksum(@verified_address)
      end

      info do
        ens_name, ens_avatar = DiscourseSiwe::EnsResolver.resolve(@verified_address)
        if ens_name.nil? && @owner_address
          ens_name, ens_avatar = DiscourseSiwe::EnsResolver.resolve(@owner_address)
        end
        display_name = ens_name || @verified_address
        {
          nickname: display_name,
          name: display_name,
          image: ens_avatar
        }
      end

      # Owner EOA of the Light Account that signed in, when the signature
      # proves it (see LightAccount.owner_from_signature).
      extra do
        { owner_address: @owner_address }
      end

      def request_phase
        query_string = env['QUERY_STRING']
        redirect "/discourse-siwe/auth?#{query_string}"
      end

      def callback_phase
        eth_message_crlf = request.params['eth_message']
        eth_message = eth_message_crlf.encode(eth_message_crlf.encoding, universal_newline: true)
        eth_signature = request.params['eth_signature']
        siwe_message = ::Siwe::Message.from_message(eth_message)

        domain = Discourse.base_url.delete_prefix("#{Discourse.base_protocol}://")
        if siwe_message.domain != domain
          return fail!("Invalid domain")
        end

        nonce = session.delete(:nonce)
        if siwe_message.nonce != nonce
          return fail!("Invalid nonce")
        end

        @verified_address = siwe_message.address

        failure_reason = nil
        begin
          siwe_message.validate(eth_signature)
        rescue ::Siwe::ExpiredMessage
          failure_reason = :expired_message
        rescue ::Siwe::NotValidMessage
          failure_reason = :invalid_message
        rescue ::Siwe::InvalidSignature
          # EOA verification failed — try EIP-6492 universal validator which handles
          # both deployed wallets (EIP-1271, e.g. Safe) and undeployed accounts
          # (EIP-6492, e.g. Coinbase Smart Wallet)
          unless smart_wallet_valid?(siwe_message, eth_signature)
            failure_reason = :invalid_signature
          end
        end

        return fail!(failure_reason) if failure_reason

        @owner_address = DiscourseSiwe::LightAccount.owner_from_signature(@verified_address, eth_signature)

        super
      end

      private

      # Universal smart-wallet signature verification using the EIP-6492
      # off-chain validator. A single eth_call (contract creation simulation)
      # that handles deployed EIP-1271 wallets (e.g. Safe) AND undeployed
      # ERC-4337 accounts (e.g. Coinbase Smart Wallet) in one shot.
      def smart_wallet_valid?(siwe_message, signature)
        return false unless DiscourseSiwe::EthRpc.rpc_url

        # Hash the message the same way personal_sign does (EIP-191)
        prefixed = Eth::Signature.prefix_message(siwe_message.prepare_message)
        message_hash = Eth::Util.bin_to_hex(Eth::Util.keccak256(prefixed))

        # ABI-encode constructor args: (address signer, bytes32 hash, bytes signature)
        address_param = Eth::Util.remove_hex_prefix(siwe_message.address).downcase.rjust(64, '0')
        hash_param = message_hash.rjust(64, '0')
        sig_bytes = Eth::Util.remove_hex_prefix(signature)
        # bytes offset: 3 × 32 = 96 = 0x60
        bytes_offset = "0000000000000000000000000000000000000000000000000000000000000060"
        sig_length = (sig_bytes.length / 2).to_s(16).rjust(64, '0')
        sig_padded = sig_bytes.ljust(((sig_bytes.length + 63) / 64) * 64, '0')

        data = "0x#{EIP6492_VALIDATOR_BYTECODE}#{address_param}#{hash_param}#{bytes_offset}#{sig_length}#{sig_padded}"

        # eth_call with no 'to' simulates contract creation
        result = DiscourseSiwe::EthRpc.eth_call(nil, data)
        return false if result.nil?

        # Validator returns 0x01 (possibly zero-padded to 32 bytes) for valid
        result.gsub(/\A0+/, '') == '1'
      end
    end
  end
end
