class PayrollDashboardPolicy < ApplicationPolicy
  # The payroll dashboard is pure analytics (trends, branch cost breakdown,
  # top-employee rankings, health score) — gated separately from `view_payroll`.
  def index? = can?(:view_payroll_analytics)
end
