class EmployeeRequestPolicy < ApplicationPolicy
  def index?   = true  # scope handles per-role data isolation
  def show?    = super_admin? || accountant? || own_request? || manages_requester?
  def approve? = super_admin? || manages_requester?
  def reject?  = super_admin? || manages_requester?
  def pay?     = (super_admin? || accountant?) && same_business?(record.user)
  def update?  = own_request? && record.pending?
  def destroy? = false

  def new?
    employee? || branch_manager? || area_manager? || super_admin?
  end

  def create?
    return false unless same_business?(record.user)
    return true  if record.user_id == user.id
    (branch_manager? || area_manager?) && record.user&.manager_id == user.id
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.super_admin? || user.accountant?
        scope.for_business(user.business)
      elsif user.area_manager?
        managed_ids = user.managed_employee_ids
        scope.where(
          EmployeeRequest.arel_table[:user_id].eq(user.id)
          .or(EmployeeRequest.arel_table[:user_id].in(managed_ids))
        )
      elsif user.branch_manager?
        scope.where(
          EmployeeRequest.arel_table[:user_id].eq(user.id)
          .or(EmployeeRequest.arel_table[:user_id].in(user.managed_employee_ids))
        )
      else
        scope.where(user_id: user.id)
      end
    end
  end

  private

  def own_request?
    record.user_id == user.id
  end

  def manages_requester?
    (branch_manager? || area_manager?) && record.user.manager_id == user.id
  end
end
