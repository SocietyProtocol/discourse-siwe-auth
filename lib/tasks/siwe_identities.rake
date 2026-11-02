# frozen_string_literal: true

namespace :siwe do
  desc 'Backfill web3 identity custom fields for existing SIWE users'
  task :migrate_identities, [:dry_run] => :environment do |_t, args|
    dry_run = args[:dry_run] == 'true'
    migrated = 0

    UserAssociatedAccount.where(provider_name: 'siwe').find_each do |assoc|
      user = assoc.user
      next unless user

      wallet = assoc.provider_uid&.downcase
      next if wallet.blank? || user.custom_fields['wallet_address'].present?

      puts "#{dry_run ? '[dry-run] ' : ''}Migrating #{user.username} (ID: #{user.id})"

      unless dry_run
        user.custom_fields['wallet_address'] = wallet

        ens_name, ens_avatar = DiscourseSiwe::EnsResolver.resolve(wallet)
        user.custom_fields['ens_name']   = ens_name   if ens_name
        user.custom_fields['ens_avatar'] = ens_avatar if ens_avatar

        society = DiscourseSiwe::IdentityResolver.resolve_with_owner(
          wallet, user.custom_fields['siwe_owner_address'],
        )
        DiscourseSiwe::IdentityStore.store_society(user, society)
        user.custom_fields['preferred_identity'] =
          DiscourseSiwe::IdentityStore.default_preference(user.custom_fields)

        user.save_custom_fields

        # Do not rewrite existing display names during bulk migration.
        # The user's display name will update the next time they log in or
        # change their preferred identity in preferences.
        sleep 0.5
      end

      migrated += 1
    end

    puts "Done. #{migrated} users #{dry_run ? 'would be' : 'were'} migrated."
  end

  desc 'Re-resolve Society profile names for every SIWE user (dry run by default: siwe:refresh_society[false] to apply)'
  task :refresh_society, [:dry_run] => :environment do |_t, args|
    dry_run = args[:dry_run] != 'false'
    failed = unchanged = updated = 0

    puts "#{dry_run ? '[dry-run] ' : ''}Refreshing Society profiles..."
    unless SiteSetting.siwe_society_subgraph_token.to_s.strip.present?
      puts 'WARNING: siwe_society_subgraph_token is empty; the query gateway will reject lookups.'
    end

    User.joins(:_custom_fields)
        .where(user_custom_fields: { name: 'wallet_address' })
        .where.not(user_custom_fields: { value: [nil, ''] })
        .find_each do |user|
      wallet = user.custom_fields['wallet_address']
      society = DiscourseSiwe::IdentityResolver.resolve_with_owner(
        wallet, user.custom_fields['siwe_owner_address'],
      )

      if society == DiscourseSiwe::IdentityResolver::LOOKUP_FAILED
        failed += 1
        puts "  #{user.username}: lookup failed, left unchanged"
        next
      end

      new_name = society.is_a?(Hash) ? society[:name].to_s : ''
      if new_name == user.custom_fields['society_name'].to_s && !new_name.empty? &&
         user.custom_fields['preferred_identity'] != 'wallet'
        unchanged += 1
        next
      end

      # Users who never picked an identity were defaulted to "wallet" when the
      # lookup was failing. Move them to Society now that a name exists.
      upgrade = !new_name.empty? && user.custom_fields['preferred_identity'] == 'wallet'
      puts "  #{user.username}: #{user.custom_fields['society_name'].inspect} -> #{new_name.inspect}" \
           "#{upgrade ? ' (preference wallet -> society)' : ''}"
      updated += 1
      next if dry_run

      DiscourseSiwe::IdentityStore.store_society(user, society)
      user.custom_fields['preferred_identity'] = 'society' if upgrade
      user.save_custom_fields
      DiscourseSiwe::DisplayNameApplier.apply(user)
      user.save!
      sleep 0.2
    end

    puts "Done. #{updated} #{dry_run ? 'would change' : 'changed'}, #{unchanged} unchanged, #{failed} failed."
    if SiteSetting.respond_to?(:prioritize_username_in_ux) && SiteSetting.prioritize_username_in_ux
      puts 'NOTE: prioritize_username_in_ux is on, so /u still lists usernames (addresses). ' \
           'Turn it off to show display names first.'
    end
  end
end
