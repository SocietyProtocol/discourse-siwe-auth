# frozen_string_literal: true

module DiscourseSiwe
  # Wires GatingConfig / GatingPlanner / GatingAudit to real Discourse.
  # Rules live in those pure modules; this file reads state and applies actions.
  #
  # The config comes from the siwe_gating_config site setting (so it is not
  # in the public plugin repo) or, for one run, from the file named in
  # SIWE_GATING_FILE.
  module GatingRunner
    STORE = 'discourse-siwe-auth'
    COLOR = '0088CC'
    TEXT_COLOR = 'FFFFFF'

    module_function

    def reserved_group_names
      Group::AUTO_GROUPS.keys.map(&:to_s) + Group.where(automatic: true).pluck(:name)
    end

    def config
      text = ENV['SIWE_GATING_FILE'] ? File.read(ENV['SIWE_GATING_FILE']) : SiteSetting.siwe_gating_config
      GatingConfig.parse(text, reserved: reserved_group_names)
    end

    def mapped_group_names
      GroupSyncRunner.mapping.keys
    end

    def state(cfg)
      levels = Group.visibility_levels
      groups = {}
      Group.where('lower(name) IN (?)', cfg.groups.keys.map(&:downcase)).each do |g|
        groups[g.name.downcase] = {
          exists: true, automatic: g.automatic, full_name: g.full_name,
          visibility: levels[g.visibility_level], members_visibility: levels[g.members_visibility_level],
          public_admission: g.public_admission, public_exit: g.public_exit,
          allow_membership_requests: g.allow_membership_requests,
        }
      end

      categories = {}
      cfg.categories.each_key do |slug|
        found = Category.where(slug: slug).to_a
        raise "category slug #{slug} is ambiguous (#{found.size} categories)" if found.size > 1
        next if found.empty?

        category = found.first
        permissions = {}
        category.category_groups.includes(:group).each do |cg|
          permissions[cg.group.name] = CategoryGroup.permission_types[cg.permission_type] if cg.group
        end
        categories[slug] = { id: category.id, permissions: permissions, public: !category.read_restricted }
      end
      # Parents outside the config only need to exist.
      cfg.categories.each_value do |c|
        next if !c[:parent] || categories.key?(c[:parent]) || cfg.categories.key?(c[:parent])

        parent = Category.find_by(slug: c[:parent])
        categories[c[:parent]] = { id: parent.id, permissions: {}, public: !parent.read_restricted } if parent
      end
      { groups: groups, categories: categories }
    end

    def plan(cfg = config)
      GatingPlanner.plan(cfg, state(cfg), mapped_groups: mapped_group_names)
    end

    # Applies the plan. Returns the list of human-readable lines it applied.
    def apply(plan, cfg)
      applied = []
      done_permissions = {}
      plan.actions.each do |a|
        case a.type
        when :create_group
          create_group(cfg.groups.fetch(a.target), a.details[:attrs])
          applied << "created group #{a.target}"
        when :update_group
          update_group(a.target, a.details[:changes])
          applied << "updated group #{a.target}"
        when :create_category
          # Created already restricted, never public for a moment.
          perms = plan.actions.find { |x| x.type == :set_permissions && x.target == a.target }
          create_category(a.target, a.details, perms.details[:desired])
          done_permissions[a.target] = true
          applied << "created category #{a.target}"
        when :set_permissions
          next if done_permissions[a.target]

          set_permissions(a.target, a.details[:desired])
          applied << "set permissions on #{a.target}"
        end
      end
      applied.each { |line| audit(line) }
      applied
    end

    def create_group(group, attrs)
      levels = Group.visibility_levels
      Group.create!(
        name: group[:name], full_name: attrs[:full_name],
        visibility_level: levels[attrs[:visibility]], members_visibility_level: levels[attrs[:members_visibility]],
        public_admission: false, public_exit: false, allow_membership_requests: false,
      )
    end

    def update_group(name, changes)
      levels = Group.visibility_levels
      group = Group.where('lower(name) = ?', name.downcase).first!
      attrs = {}
      changes.each do |key, (_from, to)|
        case key
        when :visibility then attrs[:visibility_level] = levels[to]
        when :members_visibility then attrs[:members_visibility_level] = levels[to]
        else attrs[key] = to
        end
      end
      group.update!(attrs)
    end

    def permission_params(desired)
      desired.each_with_object({}) do |(group_name, level), out|
        group = Group.where('lower(name) = ?', group_name.downcase).first!
        out[group.id] = level
      end
    end

    def create_category(slug, details, desired)
      parent = details[:parent] && Category.find_by(slug: details[:parent])
      Category.create!(
        name: details[:name], slug: slug, user: Discourse.system_user,
        parent_category_id: parent&.id, color: COLOR, text_color: TEXT_COLOR,
        permissions: permission_params(desired),
      )
    end

    def set_permissions(slug, desired)
      category = Category.find_by!(slug: slug)
      category.set_permissions(permission_params(desired))
      category.save!
    end

    def audit(line)
      StaffActionLogger.new(Discourse.system_user).log_custom('siwe_gating', details: line)
    end

    # Members of each gated group who the next enforce would remove, who have
    # no wallet, or who sit in a group no badge feeds. Read-only.
    def audit_report(cfg = config)
      gated = cfg.categories.values.flat_map { |c| c[:access].keys }.uniq
      mapped = mapped_group_names
      unmapped = gated - mapped
      sync = GroupSyncRunner.run(mode: 'log', persist_state: false)

      walletless = {}
      manual = {}
      gated.each do |name|
        group = Group.where('lower(name) = ?', name.downcase).first
        next unless group

        users = group.users.where(admin: false, moderator: false).where.not(id: group.group_users.where(owner: true).select(:user_id))
        usernames = users.pluck(:id, :username)
        ids = usernames.map(&:first)
        with_wallet = UserCustomField.where(user_id: ids, name: %w[wallet_address siwe_owner_address]).where.not(value: [nil, '']).pluck(:user_id).uniq
        names = usernames.to_h
        walletless[name] = (ids - with_wallet).map { |id| names[id] }
        manual[name] = usernames.map(&:last) if unmapped.include?(name)
      end

      GatingAudit.report(sync, gated: gated, walletless: walletless, unmapped: unmapped, manual: manual)
    end
  end
end
