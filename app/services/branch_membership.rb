# Single source of truth for "which branch(es) does an employee belong to?" and
# "who manages this employee?".
#
# Branch membership is derived EXCLUSIVELY from active ShiftAssignments — there is
# no separate membership table. Management hierarchy is inferred through the
# employee's branch:
#
#   Employee → active ShiftAssignment → Branch → branch_manager_id / area_manager_id
#
# Current-day screens use #current_branch_ids / #current_member_ids (active today).
# Payroll and historical reports must use the period-aware ShiftAssignment helpers
# (ShiftAssignment.branch_ids_for_users / branch_names_by_user) with the report's
# date window — never the current-day helpers here.
module BranchMembership
  module_function

  # Branch ids the user is currently assigned to (active today). nil branch_ids
  # (unassigned shifts) contribute no membership and are stripped.
  def current_branch_ids(user)
    ShiftAssignment.current.where(user_id: user.id).distinct.pluck(:branch_id).compact
  end

  # Chainable subquery of user_ids currently assigned to any of `branch_ids`.
  # Returns a relation so callers can use it as a WHERE IN subquery without
  # loading ids into memory.
  def current_member_ids(branch_ids)
    ShiftAssignment.user_ids_for_branches(branch_ids)
  end

  # True when the branch still has an assignment in effect on or after `on` —
  # current or upcoming, i.e. not ended before `on` (effective_to is inclusive).
  # An ended assignment is history and does not count.
  def effective_assignments_at?(branch_id, on:)
    ShiftAssignment.where(branch_id: branch_id)
                   .where("effective_to IS NULL OR effective_to >= ?", on)
                   .exists?
  end

  # The managers of `user`, inferred through the branches they are currently
  # assigned to: each branch's branch_manager_id + area_manager_id. Returns a
  # de-duplicated array of User ids, excluding the user themselves.
  def manager_ids(user)
    branch_ids = current_branch_ids(user)
    return [] if branch_ids.empty?

    Branch.where(id: branch_ids)
          .pluck(:branch_manager_id, :area_manager_id)
          .flatten.compact.uniq - [ user.id ]
  end
end
