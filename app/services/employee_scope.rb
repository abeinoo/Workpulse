# Single authoritative resolver for "which employees can this user access?"
#
# Branch membership is shift-driven: an employee belongs to a branch while they
# hold an active ShiftAssignment to it. It is Workforce data, read only through
# the OrganizationAccess::MembershipProvider contract. Management is the
# branch's branch_manager_id / area_manager_id. There is no direct
# employee→manager ownership and no UserBranch membership.
#
# Hierarchy (highest wins; levels are additive, not exclusive):
#
#   Owner          → every non-owner user in the business
#   Area manager   → employees assigned to branches they area-manage (or manage)
#   Branch manager → employees assigned to branches they manage
#   Employee       → User.none  (self access is handled at the policy level, not here)
#
# Permission data scopes (stored per-permission on PermissionRole):
#   self     → only the user themselves
#   branch   → employees assigned to branches where the user is branch_manager_id
#   area     → employees assigned to branches where the user is area_manager_id
#   business → every employee in the business
#
# branch and area are strictly role-based: a user who merely works in a branch
# (an active assignment, but not its manager) gets nobody from these scopes —
# only self (added back by the policy layer). Employees without any active
# ShiftAssignment belong to no branch/area and surface only under business.
#
# Usage:
#   EmployeeScope.new(user).relation          # canonical "what does this manager see?"
#   EmployeeScope.new(user).for_scope("branch")       # explicit named-scope override
#   EmployeeScope.new(user).includes?(other_user_id)  # record-level guard
#
class EmployeeScope
  # New canonical scope names plus legacy aliases, kept resolvable until the
  # legacy values are fully migrated out (Phase 5 cleanup). PermissionRole
  # normalizes stored scopes to the canonical names; the aliases here defend
  # against any un-migrated callers/data in the meantime.
  SCOPE_RESOLVERS = {
    "self"     => :self_only,
    "branch"   => :branch,
    "area"     => :area,
    "business" => :business_wide,
    # legacy → canonical
    "self_only"              => :self_only,
    "branch_only"            => :branch,
    "business_wide"          => :business_wide
  }.freeze

  def initialize(user)
    @user = user
  end

  # The canonical managed-employee relation for this user — the natural hierarchy
  # used when no explicit data scope is configured. Branch managers and area
  # managers see everyone currently assigned to the branches they oversee.
  # Returns an AR relation that can be chained (.active, .select(:id), .exists?).
  def relation
    return business_wide if @user.owner?

    members_in(@user.managed_branch_ids + @user.area_managed_branch_ids)
  end

  # Resolve a named scope string to a concrete AR relation.
  # Called by policies when an explicit scope override is configured.
  def for_scope(scope_name)
    method_name = SCOPE_RESOLVERS.fetch(scope_name.to_s, nil)
    method_name ? send(method_name) : relation
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
  # *explicit* scope still takes precedence over a broader one.
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

  # "branch" scope: employees assigned to the branches this user manages as
  # branch_manager_id. Role-based only — no own-assigned fallback.
  def branch
    members_in(@user.managed_branch_ids)
  end

  # "area" scope: employees assigned to the branches in the user's area
  # (area_manager_id). Role-based only — no own-assigned or managed fallback.
  def area
    members_in(@user.area_managed_branch_ids)
  end

  def business_wide
    base
  end

  # Employees (excluding self) currently belonging to any of `branch_ids`. The
  # single membership primitive every scope is built on; the member ids come from
  # the OrganizationAccess::MembershipProvider contract as a subquery.
  def members_in(branch_ids)
    ids = branch_ids.uniq
    return User.none unless ids.any?

    base.where(User.arel_table[:id].in(OrganizationAccess::MembershipProvider.current_member_ids(ids).arel))
  end
end
