# frozen_string_literal: true

namespace :siwe do
  namespace :gating do
    def gating_config!
      cfg = DiscourseSiwe::GatingRunner.config
      if cfg.errors.any?
        puts 'The gating config has problems:'
        cfg.errors.each { |e| puts "  - #{e}" }
        abort 'Fix the config (siwe_gating_config, or SIWE_GATING_FILE) and run again.'
      end
      cfg
    end

    def print_plan(plan)
      plan.warnings.each { |w| puts "  warning: #{w}" }
      if plan.empty?
        puts '  nothing to change: the forum already matches the config.'
        return
      end
      plan.actions.each do |a|
        case a.type
        when :create_group then puts "  create group #{a.target}"
        when :update_group then puts "  update group #{a.target}: #{a.details[:changes].map { |k, (from, to)| "#{k} #{from.inspect} -> #{to.inspect}" }.join(', ')}"
        when :create_category then puts "  create category #{a.target}#{a.details[:parent] ? " under #{a.details[:parent]}" : ''}"
        when :set_permissions
          puts "  set permissions on #{a.target}: #{a.details[:desired].map { |g, l| "#{g}=#{l}" }.join(' ')} (was: #{a.details[:current].map { |g, l| "#{g}=#{l}" }.join(' ').presence || 'none'})"
        when :blocked then puts "  BLOCKED #{a.target}: #{a.details[:reason]}"
        end
      end
    end

    desc 'Create/repair the gated groups and category permissions from siwe_gating_config. Dry run unless siwe:gating:provision[apply]'
    task :provision, [:mode] => :environment do |_t, args|
      apply = args[:mode] == 'apply'
      cfg = gating_config!
      plan = DiscourseSiwe::GatingRunner.plan(cfg)
      puts apply ? 'Applying:' : 'Dry run (use siwe:gating:provision[apply] to change anything):'
      print_plan(plan)
      next unless apply

      if plan.blocked.any?
        puts "#{plan.blocked.size} item(s) are blocked and were skipped; everything else was applied."
      end
      lines = DiscourseSiwe::GatingRunner.apply(plan, cfg)
      puts lines.empty? ? 'Nothing applied.' : lines.map { |l| "  done: #{l}" }.join("\n")
    end

    desc 'Show drift between siwe_gating_config and the forum, plus who the badge sync would add or remove'
    task status: :environment do
      cfg = gating_config!
      puts 'Config vs forum:'
      print_plan(DiscourseSiwe::GatingRunner.plan(cfg))
      puts 'Group membership vs chain (log mode, nothing changed):'
      result = DiscourseSiwe::GroupSyncRunner.run(mode: 'log', persist_state: false)
      puts "  sync status: #{result[:status]}#{result[:error] ? " (#{result[:error]})" : ''}"
      gated = cfg.categories.values.flat_map { |c| c[:access].keys }.uniq
      (result[:groups] || {}).slice(*gated).each do |name, g|
        if g[:missing]
          puts "  #{name}: group missing"
        else
          puts "  #{name}: add #{g[:add].size}, remove #{g[:remove].size}, awaiting confirmation #{g[:deferred].size}, kept #{g[:kept].size}#{' BRAKED' if g[:braked]}"
        end
      end
    end

    desc 'Pre-enforcement audit: who would lose access, who has no wallet, which gated groups are hand-managed'
    task audit: :environment do
      cfg = gating_config!
      report = DiscourseSiwe::GatingRunner.audit_report(cfg)
      report[:groups].each do |name, g|
        puts "#{name}:"
        puts "  would lose access (no badge): #{g[:lose_access].join(', ')}" if g[:lose_access].any?
        puts "  no wallet on record (keep access forever): #{g[:walletless].join(', ')}" if g[:walletless].any?
        puts "  staff/owners/exempt (never removed): #{g[:kept].join(', ')}" if g[:kept].any?
        puts "  hand-managed members (no badge feeds this group): #{g[:manual_members].join(', ')}" if g[:manual_members].any?
        puts '  group does not exist yet' if g[:missing]
      end
      if report[:ok]
        puts 'AUDIT CLEAN: safe to restrict categories to these groups.'
      else
        puts 'AUDIT FAILED. Resolve each item (remove, grandfather via siwe_group_sync_exempt_usernames, or give a badge):'
        report[:blockers].each { |b| puts "  - #{b}" }
        exit 1
      end
    end
  end
end
