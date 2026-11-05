# frozen_string_literal: true

require 'set'

module DiscourseSiwe
  # Pure decision logic for one group: who to add and who to remove. No
  # Discourse, no I/O, so every rule is unit tested.
  #
  # Rules:
  #   * add:    holders who are not in the group yet.
  #   * remove: members who no longer hold, except protected members (owners,
  #             staff, the exempt list) and members whose holdings could not
  #             be determined ("unknown", never treated as "not holding").
  #   * a member must be seen absent `confirmations` runs in a row before
  #     removal, which covers a transient zero while a migration batch moves
  #     a badge from E to S.
  #   * brake: if more members than max(floor, percent of the group) would be
  #     removed at once, remove nobody from this group and flag it.
  module GroupSyncPlanner
    Plan = Struct.new(:add, :remove, :deferred, :kept, :braked, :next_pending, keyword_init: true)

    module_function

    # desired/current/protected/unknown: Sets of user ids.
    # pending: { user_id => runs already seen absent }.
    def plan(desired:, current:, protected:, unknown:, pending: {}, confirmations: 2, floor: 3, percent: 20)
      add = (desired - current).to_a.sort
      absent = current - desired - unknown
      kept = (absent & protected).to_a.sort
      candidates = absent - protected

      next_pending = {}
      due = []
      candidates.each do |user_id|
        seen = pending.fetch(user_id, 0) + 1
        next_pending[user_id] = seen
        due << user_id if seen >= confirmations
      end

      limit = [floor.to_i, (current.size * percent.to_f / 100).ceil].max
      braked = due.size > limit
      remove = braked ? [] : due.sort

      Plan.new(
        add: add,
        remove: remove,
        deferred: (candidates.to_a - due).sort,
        kept: kept,
        braked: braked,
        next_pending: next_pending,
      )
    end
  end
end
