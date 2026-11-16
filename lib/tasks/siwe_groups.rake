# frozen_string_literal: true

namespace :siwe do
  namespace :groups do
    desc 'Create the groups named in siwe_group_badge_mapping (dry run by default: siwe:groups:bootstrap[false] to create)'
    task :bootstrap, [:dry_run] => :environment do |_t, args|
      dry_run = args[:dry_run] != 'false'
      mapping = DiscourseSiwe::GroupSyncRunner.mapping
      abort 'siwe_group_badge_mapping is empty or has no valid entries.' if mapping.empty?

      mapping.each_key do |name|
        if Group.where('lower(name) = ?', name.downcase).exists?
          puts "  #{name}: exists, left as is"
          next
        end

        puts "  #{name}: #{dry_run ? 'would create' : 'creating'}"
        next if dry_run

        # Closed by default: membership comes from the chain only. Admins can
        # loosen visibility afterwards; the sync never touches these settings.
        Group.create!(
          name: name,
          visibility_level: Group.visibility_levels[:members],
          members_visibility_level: Group.visibility_levels[:staff],
          public_admission: false,
          public_exit: false,
          allow_membership_requests: false,
          grant_trust_level: nil,
        )
      end
      puts dry_run ? 'Dry run: nothing created.' : 'Done.'
    end

    desc 'Sync groups with badge holders. Mode log (default) only reports; siwe:groups:sync[enforce] applies'
    task :sync, [:mode] => :environment do |_t, args|
      mode = args[:mode].presence || 'log'
      abort "mode must be log or enforce, got #{mode.inspect}" unless %w[log enforce].include?(mode)

      # A manual log run must not advance the removal counters.
      result = DiscourseSiwe::GroupSyncRunner.run(mode: mode, persist_state: mode == 'enforce')
      print_report(result)
    end

    desc 'Show the last full group sync report'
    task report: :environment do
      report = DiscourseSiwe::GroupSyncRunner.last_report
      abort 'No group sync has run yet.' unless report

      print_report(report.deep_symbolize_keys)
    end

    def print_report(result)
      puts "status: #{result[:status]} (mode #{result[:mode]})#{result[:at] ? " at #{result[:at]}" : ''}"
      puts "error: #{result[:error]}" if result[:error]
      (result[:groups] || {}).each do |name, g|
        if g[:missing]
          puts "  #{name}: group does not exist (run siwe:groups:bootstrap)"
          next
        end
        puts "  #{name}:"
        puts "    add:      #{g[:add].join(', ')}" if g[:add].any?
        puts "    remove:   #{g[:remove].join(', ')}" if g[:remove].any?
        puts "    deferred: #{g[:deferred].join(', ')} (absent, awaiting confirmation)" if g[:deferred].any?
        puts "    kept:     #{g[:kept].join(', ')} (staff/owner/exempt)" if g[:kept].any?
        puts '    BRAKED: too many removals at once, none applied' if g[:braked]
        puts '    no changes' if g.values_at(:add, :remove, :deferred, :kept).all?(&:empty?) && !g[:braked]
      end
    end
  end
end
