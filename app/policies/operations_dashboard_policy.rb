class OperationsDashboardPolicy < ApplicationPolicy
  def index? = managing? || can?(:view_payroll)
end
