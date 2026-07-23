class Laundry::BaseController < ApplicationController
  before_action :authenticate_user!
  before_action :require_laundry_access!

  private

  # Any laundry permission (operational OR cost-reporting) grants entry to the
  # module; individual actions are still gated by their own, more specific
  # Pundit policies/checks — this only keeps out users with no laundry access
  # at all (e.g. an accountant with only laundry_cost_reports must still get
  # past this gate to reach the cost report controllers).
  LAUNDRY_PERMISSIONS = (PermissionRole::PERMISSION_GROUPS[:laundry_operations] +
                         PermissionRole::PERMISSION_GROUPS[:laundry_cost_reports]).map(&:to_sym).freeze

  def require_laundry_access!
    return if LAUNDRY_PERMISSIONS.any? { |p| current_user.can?(p) }

    redirect_to root_path, alert: t("flash.not_authorized")
  end

  # Active branches the current user may attribute towel activity to, honouring
  # their branch scope. Laundry staff are typically shift-assigned rather than
  # branch/area-managed, so — unlike Finance::BaseController#assignable_branches,
  # which this otherwise mirrors — branch scope here also resolves from the
  # user's active ShiftAssignment (see BranchScope).
  #
  # `permissions` is an ordered, most-specific-first list of permission names
  # (mirrors ApplicationPolicy#resolved_branch_scope) — the first one with an
  # explicitly configured data scope wins (e.g. a business-wide
  # create_towel_transfers override), else :view_towel_balances's own scope,
  # else the hierarchy default. Without this, a user configured for "business"
  # scope would still only see their managed/shift-assigned branches here.
  def assignable_branches(*permissions)
    return current_user.business.branches.active.order(:name) if current_user.owner?

    permissions = [ :view_towel_balances ] if permissions.empty?
    scope_type = permissions.filter_map { |p| current_user.scope_for(p) }.first || :default
    ids = BranchScope.new(current_user, include_shift_assignments: true).for_scope(scope_type)
    current_user.business.branches.active.where(id: ids).order(:name)
  end
  helper_method :assignable_branches

  def laundry_towel_types
    current_user.business.towel_types.active.order(:name)
  end
  helper_method :laundry_towel_types
end
