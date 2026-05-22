class EmployeeRequestPolicy < ApplicationPolicy
  def index?   = true  # scope handles isolation
  def show?    = can?(:view_requests) || owner? || own_request? || manages_requester?
  def approve? = can?(:approve_requests) || owner? || manages_requester?
  def reject?  = can?(:approve_requests) || owner? || manages_requester?
  def pay?     = (can?(:pay_advances) || owner?) && same_business?(record.user)
  def update?  = own_request? && record.pending?
  def destroy? = false
  def new?     = create?

  def create?
    return false unless same_business?(record.user)
    return true  if record.user_id == user.id

    (can?(:approve_requests) || manages_branch?) && record.user&.manager_id == user.id
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.owner? || user.can?(:view_requests)
        scope.for_business(user.business)
      else
        scope.where(user_id: [ user.id ] + user.managed_employee_ids)
      end
    end
  end

  private

  def own_request?
    record.user_id == user.id
  end

  def manages_requester?
    record.user.manager_id == user.id
  end
end
