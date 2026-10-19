# frozen_string_literal: true

module DiscourseSiwe
  # Pure planning half of script/rewrite_smart_account_users.rb: decides, per
  # siwe UserAssociatedAccount, whether its EOA uid moves to the owner's Light
  # Account. No ActiveRecord here so it can be unit tested standalone.
  module SmartAccountRewrite
    module_function

    # EIP-7702 delegated EOAs carry code 0xef0100 || delegate; still EOAs.
    EIP7702_PREFIX = 'ef0100'

    # Statuses that change nothing. :adopt and :recase only record the owner
    # and/or fix the case; :rewrite and :duplicate move the uid.
    SKIP = %i[invalid orphan already smart_of light_account contract unknown_code review].freeze

    # forum-address-map.json is either { eoa => smart } or chain-keyed
    # { "1" => { eoa => smart }, "11155111" => { ... } }.
    def address_pairs(json)
      json.flat_map { |key, value| value.is_a?(Hash) ? value.to_a : [[key, value]] }
    end

    # Raises unless every pair matches our CREATE2 derivation exactly
    # (checksummed). Run before writing anything.
    def self_test!(pairs)
      raise 'self-test: address map has no pairs' if pairs.empty?

      pairs.each do |eoa, smart|
        derived = LightAccount.address(eoa)
        unless derived == LightAccount.checksum(smart) && LightAccount.same_address?(derived, smart)
          raise "self-test: #{eoa} derives #{derived}, map says #{smart}"
        end
      end
      pairs.size
    end

    # rows: [{ id:, user_id:, username:, uid:, owner:, created_at: }]
    #   owner      - siwe_owner_address custom field of the row's user, or nil
    #   created_at - row creation time (only compared to suspect_after)
    # code_for: ->(address) { code hex | '' | nil }, or nil to skip the check.
    # suspect_after: rows created after this are left for review.
    # known_pairs: [[eoa, smart]] from forum-address-map.json. A row whose uid
    #   is a known S is already moved, even with no siwe_owner_address (rows
    #   a lowercase-only rewrite left, or rows made by the Light Account
    #   login); never derive LA(S) from it.
    #
    # Returns one { row:, status:, from:, to:, other:, owner:, note: } per
    # row; owner is the EOA to store in siwe_owner_address, when missing.
    def plan(rows, code_for: nil, suspect_after: nil, known_pairs: [])
      known = { owner_of_smart: {}, eoas: {} }
      known_pairs.each do |eoa, smart|
        known[:owner_of_smart][smart.to_s.downcase] = eoa.to_s.downcase
        known[:eoas][eoa.to_s.downcase] = true
      end

      by_uid = {}
      rows.each { |r| by_uid[r[:uid].to_s.downcase] = r }

      derived = {}
      rows.each do |r|
        derived[r[:id]] = LightAccount.address(r[:uid]) if LightAccount.valid_address?(r[:uid])
      end
      smart_of = {}
      rows.each do |r|
        s = derived[r[:id]]
        smart_of[s.downcase] = r if s
      end

      rows.map { |r| plan_row(r, derived[r[:id]], by_uid, smart_of, code_for, suspect_after, known) }
    end

    def plan_row(row, smart, by_uid, smart_of, code_for, suspect_after, known = { owner_of_smart: {}, eoas: {} })
      uid = row[:uid].to_s
      entry = { row: row, from: uid, to: nil, other: nil, owner: nil, note: nil }

      return entry.merge(status: :invalid, note: 'uid is not an address') unless smart
      return entry.merge(status: :orphan, note: 'no user') unless row[:user_id]

      owner = row[:owner]
      recorded = LightAccount.valid_address?(owner) && LightAccount.same_address?(LightAccount.address(owner), uid)
      mapped = known[:owner_of_smart][uid.downcase]
      if recorded || mapped
        checksummed = LightAccount.checksum(uid)
        set_owner = recorded ? nil : mapped
        note = recorded ? "owner #{owner}" : "owner #{mapped} from the address map"
        if checksummed == uid
          return entry.merge(status: set_owner ? :adopt : :already, owner: set_owner, note: note)
        end

        return entry.merge(status: :recase, to: checksummed, owner: set_owner, note: note)
      end

      eoa_row = smart_of[uid.downcase]
      if eoa_row && eoa_row[:id] != row[:id]
        return entry.merge(
          status: :smart_of, other: eoa_row,
          note: "Light Account of #{eoa_row[:uid]} (row #{eoa_row[:id]})",
        )
      end

      # The strategy's uid has always been the SIWE message address, which is
      # EIP-55 checksummed. Another case means a script or a hand edit wrote
      # it (the first rewrite stored S lowercase), so it may already be a
      # Light Account: leave it unless it is a known wallet.
      if uid != LightAccount.checksum(uid) && !known[:eoas][uid.downcase]
        return entry.merge(
          status: :review,
          note: 'uid not checksummed and not in the address map; may already be a Light Account',
        )
      end

      if code_for
        code = code_for.call(uid)
        return entry.merge(status: :unknown_code, note: 'eth_getCode failed') if code.nil?

        code = code.downcase
        if code == LightAccount.proxy_runtime_code
          return entry.merge(status: :light_account, note: 'deployed Light Account, owner unknown')
        end
        if !code.empty? && !code.start_with?(EIP7702_PREFIX)
          return entry.merge(status: :contract, note: 'contract wallet, not an EOA')
        end
      end

      if suspect_after && row[:created_at] && row[:created_at] > suspect_after
        return entry.merge(status: :review, to: smart, note: "created after #{suspect_after}")
      end

      existing = by_uid[smart.downcase]
      if existing && existing[:id] != row[:id]
        return entry.merge(
          status: :duplicate, to: smart, other: existing,
          note: "#{smart} already used by user #{existing[:user_id]} (#{existing[:username]})",
        )
      end

      entry.merge(status: :rewrite, to: smart)
    end

    # Same shortening DisplayNameApplier uses for the 'wallet' identity.
    def short_wallet(wallet)
      w = wallet.to_s.downcase
      "#{w[0..5]}…#{w[-4..-1]}"
    end
  end
end
