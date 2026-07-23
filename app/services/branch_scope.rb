# Resolver for "which branches can this user access?" — the branch-based parallel
# to EmployeeScope (which answers the same question for employees). Financial
# records (expenses, custody, recurring expenses, branch revenue) are scoped by
# branch, so policies resolve their visibility through here.
#
# Branch access is management-based by default: a user accesses the branches
# they branch-manage (branch_manager_id) and/or area-manage (area_manager_id).
# Owners access every branch in the business.
#
# Some modules (Laundry) grant permissions to shift-assigned staff who are not
# branch/area managers at all — for those, pass include_shift_assignments:
# true so "branch"/"area" also resolve from the user's active ShiftAssignment
# (mirrors BranchMembership.current_branch_ids and
# Finance::BaseController#auto_assign_expense_branch's
# `shift_assignments.active_on(Date.current)` pattern). This is opt-in per
# caller — existing management-based callers (Finance) are unaffected unless
# they explicitly ask for it.
#
# Scope values are the shared PermissionRole::SCOPE_OPTIONS (also used by
# EmployeeScope); the policy layer decides which resolver applies per record type:
#   self     → no branches (own-created / own-held records are added at the policy
#              layer, mirroring EmployeeScope which excludes self by design)
#   branch   → branches where the user is branch_manager_id (+ their active
#              ShiftAssignment branch(es), when include_shift_assignments)
#   area     → branches where the user is area_manager_id (+ every branch
#              sharing an area manager with their active ShiftAssignment
#              branch(es), when include_shift_assignments)
#   business → every branch in the business
class BranchScope
  SCOPE_RESOLVERS = {
    "self"     => :none_ids,
    "branch"   => :managed_ids,
    "area"     => :area_ids,
    "business" => :business_ids,
    # legacy aliases, mirroring EmployeeScope
    "self_only"     => :none_ids,
    "branch_only"   => :managed_ids,
    "business_wide" => :business_ids
  }.freeze

  def initialize(user, include_shift_assignments: false)
    @user = user
    @include_shift_assignments = include_shift_assignments
  end

  # The natural default when no explicit data scope is configured: the branches
  # the user manages or area-manages. Owners get every branch.
  def default_ids
    return business_ids if @user.owner?

    (managed_ids + area_ids).uniq
  end

  # Branch ids for a named scope. Unknown/blank falls back to the default,
  # matching EmployeeScope#for_scope.
  def for_scope(scope_name)
    method = SCOPE_RESOLVERS.fetch(scope_name.to_s, nil)
    method ? send(method) : default_ids
  end

  private

  def none_ids = []

  def managed_ids
    ids = @user.managed_branch_ids
    ids += shift_assignment_branch_ids if @include_shift_assignments
    ids.uniq
  end

  def area_ids
    ids = @user.area_managed_branch_ids
    ids += shift_assignment_area_branch_ids if @include_shift_assignments
    ids.uniq
  end

  def business_ids = @user.business.branches.pluck(:id)

  # Every branch the user is currently, actively shift-assigned to — a user
  # can hold more than one active ShiftAssignment (e.g. covering shifts at
  # two branches at once), so this is a set, not a single branch.
  def shift_assignment_branch_ids
    ShiftAssignment.current.where(user_id: @user.id).distinct.pluck(:branch_id).compact
  end

  # "Area" for a shift-assigned (non-manager) user: every branch sharing an
  # area manager with any branch they're actively shift-assigned to — i.e.
  # their own branch's region, not branches they personally area-manage.
  def shift_assignment_area_branch_ids
    area_manager_ids = Branch.where(id: shift_assignment_branch_ids)
                             .where.not(area_manager_id: nil)
                             .distinct.pluck(:area_manager_id)
    return [] if area_manager_ids.empty?

    @user.business.branches.where(area_manager_id: area_manager_ids).pluck(:id)
  end
end
