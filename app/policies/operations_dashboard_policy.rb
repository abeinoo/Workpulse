class OperationsDashboardPolicy < ApplicationPolicy
  def index? = can?(:view_reports)
end
