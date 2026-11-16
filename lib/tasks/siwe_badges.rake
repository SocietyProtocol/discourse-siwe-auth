# frozen_string_literal: true

namespace :siwe do
  namespace :badges do
    desc 'Mirror on-chain badges now. Mode log (default) only reports; siwe:badges:sync[enforce] applies; siwe:badges:sync[enforce,force] also skips the confirmation counters and the revoke brakes'
    task :sync, %i[mode force] => :environment do |_t, args|
      mode = args[:mode].presence || 'log'
      abort "mode must be log or enforce, got #{mode.inspect}" unless %w[log enforce].include?(mode)

      force = args[:force] == 'force'
      abort 'force only makes sense with enforce' if force && mode != 'enforce'

      result = DiscourseSiwe::BadgeMirrorRunner.run_full(mode: mode, force: force)
      puts DiscourseSiwe::BadgeMirrorRunner.format_report(result)
    end

    desc 'Show the last full badge mirror report'
    task report: :environment do
      report = DiscourseSiwe::BadgeMirrorRunner.last_report
      abort 'No badge sync has run yet.' unless report

      puts DiscourseSiwe::BadgeMirrorRunner.format_report(report.to_h.deep_symbolize_keys)
    end

    desc 'Disable every Discourse system badge (dry run by default: siwe:badges:disable_system[false] to apply). Deletes nothing.'
    task :disable_system, [:dry_run] => :environment do |_t, args|
      dry_run = args[:dry_run] != 'false'
      result = DiscourseSiwe::SystemBadges.disable!(dry_run: dry_run)
      puts "#{dry_run ? 'Would disable' : 'Disabled'} #{result[:disabled].size} system badges (#{result[:already_disabled]} were already disabled)"
      result[:disabled].each { |name| puts "  #{name}" }
      inv = result[:inventory]
      puts 'Still present, left alone (decide with siwe:badges:purge_system_grants):'
      puts "  #{inv[:user_badges]} user badge grants, #{inv[:notifications]} granted_badge notifications, #{inv[:titles]} users with a badge title"
      puts "  enable_badges is #{inv[:enable_badges]} (it must stay true)"
      puts 'Dry run: nothing changed.' if dry_run
    end

    desc 'DESTRUCTIVE: delete the user badges and notifications of system badges (dry run by default: siwe:badges:purge_system_grants[false]). Take a database backup first.'
    task :purge_system_grants, [:dry_run] => :environment do |_t, args|
      dry_run = args[:dry_run] != 'false'
      ids = DiscourseSiwe::SystemBadges.system_badge_ids
      puts "System badges: #{ids.size}"
      result = DiscourseSiwe::SystemBadges.purge_grants!(dry_run: dry_run)
      puts "#{dry_run ? 'Would delete' : 'Deleted'} #{result[:user_badges]} user badges and #{result[:notifications]} notifications."
      puts 'Dry run: nothing deleted. Back up the database, then run siwe:badges:purge_system_grants[false].' if dry_run
    end
  end
end
