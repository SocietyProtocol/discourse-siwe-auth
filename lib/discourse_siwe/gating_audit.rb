# frozen_string_literal: true

module DiscourseSiwe
  # The mandatory check before a category is restricted to a badge-fed group:
  # who is in the group today without the badge that would put them there?
  # Pure; the inputs come from a log-mode group sync and the database.
  #
  #   sync_result  BadgeGroupSync#run result in log mode
  #   gated        group names used by gated categories
  #   walletless   { group => [usernames] } non-staff members with no wallet on record
  #   unmapped     group names that no badge feeds
  #   manual       { group => [usernames] } non-staff members of unmapped groups
  module GatingAudit
    module_function

    def report(sync_result, gated:, walletless: {}, unmapped: [], manual: {})
      groups = {}
      status = sync_result[:status]
      gated.each do |name|
        row = (sync_result[:groups] || {})[name] || {}
        groups[name] = {
          missing: row[:missing] == true,
          lose_access: ((row[:remove] || []) + (row[:deferred] || [])).uniq.sort,
          kept: (row[:kept] || []).sort,
          walletless: (walletless[name] || []).sort,
          unmapped: unmapped.include?(name),
          manual_members: (manual[name] || []).sort,
        }
      end

      blockers = groups.flat_map do |name, g|
        list = []
        list << "#{name}: group does not exist yet" if g[:missing]
        list << "#{name}: #{g[:lose_access].size} member(s) hold no badge and would lose access" if g[:lose_access].any?
        list << "#{name}: #{g[:walletless].size} member(s) have no wallet, so they would keep access forever" if g[:walletless].any?
        list << "#{name}: no badge feeds this group, #{g[:manual_members].size} member(s) are hand-managed" if g[:unmapped] && g[:manual_members].any?
        list
      end
      blockers.unshift("group sync could not read the chain (#{status})") unless status == :ok

      { ok: blockers.empty?, status: status, groups: groups, blockers: blockers }
    end
  end
end
