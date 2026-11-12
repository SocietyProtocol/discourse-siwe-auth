# frozen_string_literal: true

require 'json'

module DiscourseSiwe
  # Every on-chain address a forum member may hold badges on.
  #
  # Usually this is just the member's wallet_address. A member can also carry
  # a second address of the same person: a separate owner address stored in
  # the siwe_owner_address custom field, or a pair from an optional address
  # map file. Holdings are evaluated over the whole set. An address is only
  # included when it is on record: the member's own wallet, the stored owner
  # address, or a pair from the map. With neither an owner address nor a map
  # file (the normal case for a plain wallet member) the set is the wallet
  # alone.
  module MemberAddresses
    ADDRESS = /\A0x[0-9a-f]{40}\z/

    module_function

    def normalize(value)
      address = value.to_s.strip.downcase
      address.match?(ADDRESS) ? address : nil
    end

    # fields: the user's custom fields (string keys).
    # address_map: { address => paired address } (see load_address_map); {}
    # when there is no map.
    # Returns a sorted, de-duplicated array of lowercase addresses.
    def addresses_for(fields, address_map: {})
      fields ||= {}
      address_map ||= {}
      wallet = normalize(fields['wallet_address'])
      owner = normalize(fields['siwe_owner_address'])
      found = [wallet, owner]

      if wallet
        found << address_map[wallet]               # wallet is the first half of a known pair
        found << address_map.key(wallet)           # wallet is the second half of a known pair
      end
      found.compact.map { |a| normalize(a) }.compact.uniq.sort
    end

    # Reads an optional address-map file (script/forum-address-map.json, which
    # does not ship with the plugin), either a flat { address => paired } or
    # keyed by chain id ({ "1" => { address => paired } }). Keys and values
    # are lowercased. Returns {} when the path is nil or blank, the file is
    # absent, unreadable or not valid JSON, so the sync still works from the
    # user's own fields.
    def load_address_map(path, chain_id: nil)
      return {} if path.to_s.strip.empty? || !File.file?(path)

      json = JSON.parse(File.read(path))
      return {} unless json.is_a?(Hash)

      pairs = if json.values.any? { |v| v.is_a?(Hash) }
        chain_id ? (json[chain_id.to_s] || {}).to_a : json.values.select { |v| v.is_a?(Hash) }.flat_map(&:to_a)
      else
        json.to_a
      end
      pairs.each_with_object({}) do |(first, second), map|
        a = normalize(first)
        b = normalize(second)
        map[a] = b if a && b
      end
    rescue JSON::ParserError, SystemCallError
      {}
    end
  end
end
