class PayrollDashboardPolicy < ApplicationPolicy
  def index? = can?(:view_payroll) || can?(:manage_payroll)
end
