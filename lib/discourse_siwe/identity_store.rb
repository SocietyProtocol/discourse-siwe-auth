# frozen_string_literal: true

module DiscourseSiwe
  # Pure helpers for reading and writing web3 identity custom fields.
  # Used by SiweAuthenticator, RefreshSiweIdentity job, and the rake task.
  module IdentityStore
    module_function

    FIELDS = %w[
      wallet_address ens_name ens_avatar
      society_badge_id society_name society_avatar society_bio
      preferred_identity society_resolved_at
      siwe_owner_address
    ].freeze

    def store_society(user, society)
      user.custom_fields['society_badge_id'] = society&.[](:badge_id)
      user.custom_fields['society_name']    = society&.[](:name)
      user.custom_fields['society_avatar']  = society&.[](:avatar)
      user.custom_fields['society_bio']     = society&.[](:bio)
      user.custom_fields['society_resolved_at'] = Time.now.utc.iso8601
    end

    def default_preference(custom_fields)
      if nonempty?(custom_fields['society_name']) then 'society'
      elsif nonempty?(custom_fields['ens_name'])  then 'ens'
      else 'wallet'
      end
    end

    def web3_identities(user)
      cf = user.custom_fields
      {
        wallet_address: cf['wallet_address'],
        ens_name: cf['ens_name'],
        ens_avatar: cf['ens_avatar'],
        society_badge_id: cf['society_badge_id'],
        society_name: cf['society_name'],
        society_avatar: cf['society_avatar'],
        society_bio: cf['society_bio'],
        preferred_identity: cf['preferred_identity'] || 'wallet',
      }
    end

    def society_stale?(user)
      resolved_at = user.custom_fields['society_resolved_at']
      return true if resolved_at.to_s.strip.empty?
      Time.parse(resolved_at) < (Time.now.utc - 86_400)
    rescue ArgumentError
      true
    end

    def nonempty?(value)
      !value.to_s.strip.empty?
    end
  end
end
