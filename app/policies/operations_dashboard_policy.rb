class OperationsDashboardPolicy < ApplicationPolicy
  def index? = can?(:view_payroll) || can?(:view_attendance) || can?(:approve_requests)
end
