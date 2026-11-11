# frozen_string_literal: true

require 'json'

module DiscourseSiwe
  # Every on-chain address a forum member may hold badges on.
  #
  # After the smart-account migration a member signs in with a Light Account S
  # whose owner is the EOA E; their badges can sit on either. Migrated badges
  # move to S, but many badges are never migrated and stay on E (or a Safe).
  # Holdings are therefore evaluated over the whole set. An address is only
  # included when it is proven: the member's own wallet, an owner the user
  # proved by signing in (siwe_owner_address), or a pair from the CREATE2
  # address map.
  module MemberAddresses
    ADDRESS = /\A0x[0-9a-f]{40}\z/

    module_function

    def normalize(value)
      address = value.to_s.strip.downcase
      address.match?(ADDRESS) ? address : nil
    end

    # fields: the user's custom fields (string keys).
    # address_map: { eoa => smart } (see load_address_map); {} or nil when
    # there is no map.
    # Returns a sorted, de-duplicated array of lowercase addresses.
    def addresses_for(fields, address_map: {})
      fields ||= {}
      address_map ||= {}
      wallet = normalize(fields['wallet_address'])
      owner = normalize(fields['siwe_owner_address'])
      found = [wallet, owner]

      if wallet
        found << address_map[wallet]               # wallet is an EOA with a known Light Account
        found << address_map.key(wallet)           # wallet is a Light Account with a known owner
      end
      found.compact.map { |a| normalize(a) }.compact.uniq.sort
    end

    # Reads script/forum-address-map.json, which is either a flat
    # { eoa => smart } or keyed by chain id ({ "1" => { eoa => smart } }).
    # Keys and values are lowercased. Returns {} when the path is nil or
    # blank, the file is absent, unreadable or not a JSON object, so the sync
    # still works from the user's own fields.
    def load_address_map(path, chain_id: nil)
      return {} if path.to_s.strip.empty? || !File.file?(path)

      json = JSON.parse(File.read(path))
      return {} unless json.is_a?(Hash)

      pairs = if json.values.any? { |v| v.is_a?(Hash) }
        chain_id ? (json[chain_id.to_s] || {}).to_a : json.values.select { |v| v.is_a?(Hash) }.flat_map(&:to_a)
      else
        json.to_a
      end
      pairs.each_with_object({}) do |(eoa, smart), map|
        a = normalize(eoa)
        b = normalize(smart)
        map[a] = b if a && b
      end
    rescue JSON::ParserError, SystemCallError
      {}
    end
  end
end
