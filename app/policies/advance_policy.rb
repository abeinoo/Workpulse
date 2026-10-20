class AdvancePolicy < ApplicationPolicy
  # Viewing (SEC-M2-7): one's own advances (the existing own-record rule), and
  # another employee's advances only with view_payroll and the employee inside
  # the configured view_payroll scope, or — none configured — the hierarchy
  # default (EmployeeScope#for_permissions), never business-wide by default.
  def index?  = true  # the Scope isolates
  def show?   = record.is_a?(Advance) && Scope.new(user, Advance).resolve.exists?(id: record.id)
  def create? = false # created only via Requests::Approver

  class Scope < ApplicationPolicy::Scope
    def resolve
      own = scope.where(user_id: user.id)
      return own unless user.can?(:view_payroll)

      others = EmployeeScope.new(user).for_permissions(:view_payroll).where.not(id: user.id)
      scope.where(user_id: others.select(:id)).or(own)
    end
  end
end
