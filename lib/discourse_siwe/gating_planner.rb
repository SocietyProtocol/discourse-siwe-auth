# frozen_string_literal: true

module DiscourseSiwe
  # Decides what provisioning has to change, from the parsed config and the
  # current forum state. Pure: no Discourse, no I/O.
  #
  # state:
  #   groups:     { name => { exists: true, automatic:, visibility:, members_visibility:,
  #                           public_admission:, public_exit:, allow_membership_requests:, full_name: } }
  #   categories: { slug => { permissions: { group_name => :full|:create_post|:readonly }, public: bool } }
  #
  # Only groups and categories named in the config are ever touched, and a
  # category's other attributes (name, description, order, topics) are never
  # changed. Running the plan twice yields no actions the second time.
  module GatingPlanner
    Action = Struct.new(:type, :target, :details, keyword_init: true)
    Plan = Struct.new(:actions, :warnings, keyword_init: true) do
      def blocked
        actions.select { |a| a.type == :blocked }
      end

      def changes
        actions.reject { |a| a.type == :blocked }
      end

      def empty?
        actions.empty?
      end
    end

    STAFF = 'staff'
    VISIBILITY_LEVELS = { 'members' => :members, 'staff' => :staff, 'owners' => :owners }.freeze

    module_function

    # mapped_groups: group names fed by siwe_group_badge_mapping (for warnings).
    def plan(config, state, mapped_groups: [])
      actions = []
      warnings = []
      mapped = mapped_groups.map(&:to_s)

      config.groups.each_value do |group|
        actions.concat(plan_group(group, state[:groups][group[:name]]))
        unless mapped.include?(group[:name])
          warnings << "group #{group[:name]} is not in siwe_group_badge_mapping: its membership is manual, nothing feeds it from the chain"
        end
      end

      planned_slugs = []
      ordered_categories(config.categories).each do |category|
        parent = category[:parent]
        if parent && !state[:categories].key?(parent) && !planned_slugs.include?(parent)
          actions << Action.new(type: :blocked, target: category[:slug], details: { reason: "parent category #{parent} does not exist and is not in the config" })
          next
        end

        actions.concat(plan_category(category, state[:categories][category[:slug]]))
        planned_slugs << category[:slug]
      end

      Plan.new(actions: actions, warnings: warnings)
    end

    def desired_group_attrs(group)
      owners = group[:visibility] == 'owners'
      {
        visibility: VISIBILITY_LEVELS.fetch(group[:visibility]),
        members_visibility: owners ? :owners : :staff,
        public_admission: false,
        public_exit: false,
        allow_membership_requests: false,
      }.merge(group[:full_name] ? { full_name: group[:full_name] } : {})
    end

    def plan_group(group, current)
      desired = desired_group_attrs(group)
      return [Action.new(type: :create_group, target: group[:name], details: { attrs: desired })] unless current && current[:exists]

      if current[:automatic]
        return [Action.new(type: :blocked, target: group[:name], details: { reason: 'is an automatic group and cannot be gated by badge' })]
      end

      changes = {}
      desired.each do |key, value|
        changes[key] = [current[key], value] unless current[key] == value
      end
      return [] if changes.empty?

      [Action.new(type: :update_group, target: group[:name], details: { changes: changes })]
    end

    def plan_category(category, current)
      desired = category[:access].merge(STAFF => :full)
      actions = []
      unless current
        actions << Action.new(type: :create_category, target: category[:slug], details: { name: category[:name], parent: category[:parent] })
        actions << Action.new(type: :set_permissions, target: category[:slug], details: { desired: desired, current: {} })
        return actions
      end

      existing = current[:permissions] || {}
      return [] if same_permissions?(existing, desired)

      if current[:public] && !category[:confirm_restrict]
        return [Action.new(
          type: :blocked, target: category[:slug],
          details: { reason: 'is public today; restricting it hides it from everyone outside the groups. Add confirm_restrict: true after the pre-enforcement audit' },
        )]
      end

      [Action.new(type: :set_permissions, target: category[:slug], details: { desired: desired, current: existing })]
    end

    def same_permissions?(current, desired)
      normalize(current) == normalize(desired)
    end

    def normalize(permissions)
      permissions.each_with_object({}) { |(group, level), out| out[group.to_s] = level.to_sym }
    end

    # Parents before children, otherwise config order.
    def ordered_categories(categories)
      remaining = categories.values
      ordered = []
      until remaining.empty?
        ready = remaining.select { |c| c[:parent].nil? || !categories.key?(c[:parent]) || ordered.any? { |o| o[:slug] == c[:parent] } }
        ready = [remaining.first] if ready.empty? # a cycle: surface it as a normal action
        ordered.concat(ready)
        remaining -= ready
      end
      ordered
    end
  end
end
