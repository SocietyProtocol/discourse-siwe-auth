# frozen_string_literal: true

module DiscourseSiwe
  # Parses the siwe_group_badge_mapping setting: "badge_id:group" entries
  # separated by "|", many-to-one allowed ("14:vip|15:vip|16:vip") and one
  # badge may feed several groups.
  #
  # Membership is computed per group (a member holds ANY of the group's
  # badges), never per entry, so an entry for badge 15 can not undo what the
  # entry for badge 14 just granted.
  module BadgeGroupMapping
    Result = Struct.new(:groups, :errors, keyword_init: true)

    GROUP_NAME = /\A[A-Za-z0-9_.-]{1,60}\z/

    # Names of Discourse's automatic groups. They mirror trust levels and
    # staff flags; mapping chain data onto them would let a badge change
    # someone's privileges.
    RESERVED = %w[
      everyone admins moderators staff trust_level_0 trust_level_1
      trust_level_2 trust_level_3 trust_level_4 anonymous_users logged_in_users
    ].freeze

    module_function

    # reserved: extra names to refuse (the caller passes the live
    # Group::AUTO_GROUPS keys and any automatic group).
    def parse(text, reserved: [])
      forbidden = (RESERVED + reserved.map(&:to_s)).map(&:downcase)
      groups = {}
      errors = []

      text.to_s.split('|').each do |raw|
        entry = raw.strip
        next if entry.empty?

        id_part, name = entry.split(':', 2).map { |p| p.to_s.strip }
        unless id_part.match?(/\A\d+\z/) && name && !name.empty?
          errors << "ignored \"#{entry}\": expected badge_id:group"
          next
        end
        unless name.match?(GROUP_NAME)
          errors << "ignored \"#{entry}\": invalid group name"
          next
        end
        if forbidden.include?(name.downcase)
          errors << "ignored \"#{entry}\": #{name} is an automatic group and is never managed"
          next
        end

        (groups[name] ||= []) << id_part.to_i
      end

      groups.each_value { |ids| ids.uniq!; ids.sort! }
      Result.new(groups: groups, errors: errors)
    end

    def badge_ids(groups)
      groups.values.flatten.uniq.sort
    end
  end
end
