class PayrollDashboardPolicy < ApplicationPolicy
  # The payroll dashboard is pure analytics (trends, branch cost breakdown,
  # top-employee rankings, health score) — gated separately from `view_payroll`.
  # view_payroll_analytics depends on view_payroll (PermissionRole); both are
  # required here so a role without view_payroll never reaches payroll figures.
  def index? = can?(:view_payroll_analytics) && can?(:view_payroll)
end
