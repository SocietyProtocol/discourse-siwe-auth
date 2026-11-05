# frozen_string_literal: true

require 'yaml'

module DiscourseSiwe
  # Parses and validates the token-gating configuration: which groups exist
  # and which categories those groups can see. Pure, no Discourse needed.
  #
  #   groups:
  #     vip-gold:
  #       full_name: VIP Gold              # optional
  #       visibility: members              # staff | owners | members (default)
  #   categories:
  #     gold-lounge:                       # category slug
  #       name: Gold Lounge                # used only when the category is created
  #       parent: community                # optional parent slug
  #       confirm_restrict: true           # required to restrict an existing public category
  #       access:                          # group => full | reply | read
  #         vip-gold: full
  #
  # Which badge feeds which group is NOT configured here: that is
  # siwe_group_badge_mapping. This file only says what the groups can see.
  # Staff always keep full access to every gated category.
  module GatingConfig
    Result = Struct.new(:groups, :categories, :errors, keyword_init: true)

    PERMISSIONS = { 'full' => :full, 'reply' => :create_post, 'read' => :readonly }.freeze
    VISIBILITIES = %w[members staff owners].freeze
    GROUP_NAME = /\A[a-z0-9][a-z0-9_-]{1,58}[a-z0-9]\z/.freeze
    SLUG = /\A[a-z0-9][a-z0-9-]{0,48}[a-z0-9]\z|\A[a-z0-9]\z/.freeze

    module_function

    # reserved: names of automatic groups, which can never be gated by badge.
    def parse(text, reserved: [])
      errors = []
      groups = {}
      categories = {}
      reserved = reserved.map { |n| n.to_s.downcase }

      raw = load_yaml(text, errors)
      return Result.new(groups: groups, categories: categories, errors: errors) unless raw

      unknown_top = raw.keys - %w[groups categories]
      errors << "unknown top-level key(s): #{unknown_top.join(', ')}" if unknown_top.any?

      (hash_or_empty(raw['groups'], 'groups', errors)).each do |name, attrs|
        name = name.to_s
        group = parse_group(name, attrs, reserved, errors)
        groups[name] = group if group
      end

      (hash_or_empty(raw['categories'], 'categories', errors)).each do |slug, attrs|
        slug = slug.to_s
        category = parse_category(slug, attrs, groups, errors)
        categories[slug] = category if category
      end

      Result.new(groups: groups, categories: categories, errors: errors)
    end

    def load_yaml(text, errors)
      if text.to_s.strip.empty?
        errors << 'gating config is empty'
        return nil
      end
      parsed = YAML.safe_load(text.to_s, permitted_classes: [], permitted_symbols: [], aliases: false)
      unless parsed.is_a?(Hash)
        errors << 'gating config must be a YAML mapping with groups: and categories:'
        return nil
      end
      parsed.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
    rescue Psych::Exception => e
      errors << "gating config is not valid YAML: #{e.message.lines.first.to_s.strip}"
      nil
    end

    def hash_or_empty(value, label, errors)
      return {} if value.nil?
      return value if value.is_a?(Hash)

      errors << "#{label} must be a mapping"
      {}
    end

    def parse_group(name, attrs, reserved, errors)
      attrs = {} if attrs.nil?
      unless attrs.is_a?(Hash)
        errors << "group #{name}: must be a mapping"
        return nil
      end
      unless name =~ GROUP_NAME
        errors << "group #{name}: name must be 3-60 lowercase letters, digits, - or _"
        return nil
      end
      if reserved.include?(name.downcase) || name.downcase =~ /\Atrust_level_\d\z/
        errors << "group #{name}: automatic groups cannot be gated by badge"
        return nil
      end
      attrs = attrs.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
      unknown = attrs.keys - %w[full_name visibility]
      errors << "group #{name}: unknown key(s) #{unknown.join(', ')}" if unknown.any?

      visibility = (attrs['visibility'] || 'members').to_s
      unless VISIBILITIES.include?(visibility)
        errors << "group #{name}: visibility must be one of #{VISIBILITIES.join(', ')}"
        return nil
      end
      { name: name, full_name: attrs['full_name'].to_s.strip.empty? ? nil : attrs['full_name'].to_s.strip[0, 100], visibility: visibility }
    end

    def parse_category(slug, attrs, groups, errors)
      unless attrs.is_a?(Hash)
        errors << "category #{slug}: must be a mapping"
        return nil
      end
      unless slug =~ SLUG
        errors << "category #{slug}: slug must be lowercase letters, digits and -"
        return nil
      end
      attrs = attrs.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
      unknown = attrs.keys - %w[name parent access confirm_restrict]
      errors << "category #{slug}: unknown key(s) #{unknown.join(', ')}" if unknown.any?

      access_raw = attrs['access']
      unless access_raw.is_a?(Hash) && !access_raw.empty?
        errors << "category #{slug}: access must list at least one group (a category with no access would be staff-only)"
        return nil
      end

      access = {}
      ok = true
      access_raw.each do |group, level|
        group = group.to_s
        if group.downcase == 'everyone'
          errors << "category #{slug}: 'everyone' cannot be listed; a gated category is restricted by leaving it out"
          ok = false
        elsif !groups.key?(group)
          errors << "category #{slug}: group #{group} is not defined under groups:"
          ok = false
        elsif !PERMISSIONS.key?(level.to_s)
          errors << "category #{slug}: #{group} permission must be one of #{PERMISSIONS.keys.join(', ')}"
          ok = false
        else
          access[group] = PERMISSIONS.fetch(level.to_s)
        end
      end
      return nil unless ok

      parent = attrs['parent'].to_s.strip
      if !parent.empty? && parent !~ SLUG
        errors << "category #{slug}: parent must be a slug"
        return nil
      end
      if parent == slug
        errors << "category #{slug}: parent cannot be itself"
        return nil
      end

      {
        slug: slug,
        name: (attrs['name'].to_s.strip.empty? ? slug.tr('-', ' ').capitalize : attrs['name'].to_s.strip)[0, 50],
        parent: parent.empty? ? nil : parent,
        access: access,
        confirm_restrict: attrs['confirm_restrict'] == true,
      }
    end
  end
end
