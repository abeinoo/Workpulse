# Single authoritative resolver for "which employees can this user access?"
#
# Hierarchy (highest wins; levels are additive, not exclusive):
#
#   Owner          → every non-owner user in the business
#   Area manager   → employees in area-managed branches + their own direct reports
#   Branch manager → employees in managed branches + their own direct reports
#   Direct manager → employees where manager_id == user.id
#   Employee       → User.none  (self access is handled at the policy level, not here)
#
# Usage:
#   EmployeeScope.new(user).relation          # canonical "what does this manager see?"
#   EmployeeScope.new(user).for_scope("branch_only")  # explicit named-scope override
#   EmployeeScope.new(user).includes?(other_user_id)  # record-level guard
#
class EmployeeScope
  SCOPE_RESOLVERS = {
    "self_only"              => :self_only,
    "managed_employees_only" => :managed,
    "branch_only"            => :branch,
    "business_wide"          => :business_wide
  }.freeze

  def initialize(user)
    @user = user
  end

  # The canonical managed-employee relation for this user.
  # Follows the 5-tier hierarchy and returns an AR relation that can be
  # chained (.active, .select(:id), .exists?, etc.).
  def relation
    return business_wide if @user.owner?

    branch_ids = @user.managed_branch_ids + @user.area_managed_branch_ids

    if branch_ids.any?
      direct_cond  = User.arel_table[:manager_id].eq(@user.id)
      branch_subq  = UserBranch.where(branch_id: branch_ids).select(:user_id)
      base.where(User.arel_table[:id].in(branch_subq.arel).or(direct_cond))
    elsif @user.managed_employees.exists?
      base.where(manager_id: @user.id)
    else
      User.none
    end
  end

  # Resolve a named scope string to a concrete AR relation.
  # Called by policies when an explicit scope override is configured.
  def for_scope(scope_name)
    method_name = SCOPE_RESOLVERS.fetch(scope_name.to_s, :managed)
    send(method_name)
  end

  # The canonical pickable/visible employees for one permission.
  # Thin wrapper over #for_permissions for single-permission call sites.
  def for_permission(permission)
    for_permissions(permission)
  end

  # Resolve the pickable employees for a feature using an ordered list of
  # permissions, most-specific first. The FIRST permission with an explicitly
  # configured data scope wins; if none is configured we fall back to the
  # hierarchy-based relation.
  #
  # Why a list: data scope is stored per-permission, but an admin granting a
  # "regional manager" business-wide access naturally sets it on a single
  # permission — often the broad "view_employees" or the feature's "view_*"
  # permission — not on every action permission. Reading only the action
  # permission (e.g. manage_attendance) meant such a manager fell back to their
  # hierarchy and saw only managed employees. Passing
  #   [action_permission, feature_view_permission, :view_employees]
  # lets the picker honour whichever the admin configured, while a more-specific
  # *explicit* scope still takes precedence over a broader one (so an explicit
  # managed_employees_only on the action permission is never widened).
  #
  # Mirrors ApplicationPolicy::Scope#filter_by_data_scope so pickers and record
  # visibility agree.
  def for_permissions(*permissions)
    configured = permissions.flatten.filter_map { |p| @user.scope_for(p) }.first
    configured ? for_scope(configured) : relation
  end

  # Quick boolean check for record-level policy guards.
  def includes?(user_id)
    relation.exists?(user_id)
  end

  private

  def base
    @base ||= User.where(business: @user.business).where.not(id: @user.id)
  end

  def self_only
    User.where(id: @user.id)
  end

  def managed
    relation
  end

  # "Branch only" means every employee who shares a branch with this user —
  # the branches they manage / area-manage AND the branches they personally
  # work in. Branch membership is shift-driven (active ShiftAssignment), matching
  # attendance/scheduling/dashboard; the legacy UserBranch join table is no longer
  # consulted here. A plain branch member (not the formal manager) still sees their
  # branch colleagues via their own active assignment.
  def branch
    ids = (@user.managed_branch_ids + @user.area_managed_branch_ids + own_assigned_branch_ids).uniq
    return User.none unless ids.any?

    base.where(User.arel_table[:id].in(ShiftAssignment.user_ids_for_branches(ids).arel))
  end

  # Branches the user is currently shift-assigned to (replaces @user.branch_ids,
  # which derived from UserBranch).
  def own_assigned_branch_ids
    ShiftAssignment.current.where(user_id: @user.id).distinct.pluck(:branch_id)
  end

  def business_wide
    base
  end
end
