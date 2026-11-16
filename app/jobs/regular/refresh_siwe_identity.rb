# frozen_string_literal: true

module Jobs
  class RefreshSiweIdentity < ::Jobs::Base
    def execute(args)
      return unless SiteSetting.siwe_society_enabled

      user = User.find_by(id: args[:user_id])
      return unless user
      return unless DiscourseSiwe::IdentityStore.society_stale?(user)

      wallet = user.custom_fields['wallet_address']
      return unless wallet.present?

      society = DiscourseSiwe::IdentityResolver.resolve_with_owner(
        wallet, user.custom_fields['siwe_owner_address'],
      )
      DiscourseSiwe::IdentityStore.store_society(user, society)
      user.save_custom_fields
      DiscourseSiwe::DisplayNameApplier.apply(user)
      user.save!
    end
  end
end
