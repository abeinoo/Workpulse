class EmployeeRequestPolicy < ApplicationPolicy
  def index?   = true  # scope handles isolation
  def show?    = can?(:view_requests) || can?(:approve_requests) || own_request?
  # Self-approval is blocked: an approver may not approve or reject a request they
  # themselves submitted — another authorized approver must review it. Gates the UI
  # buttons (views read policy.approve?/reject?) and the controller `authorize`.
  def approve? = can?(:approve_requests) && !own_request?
  def reject?  = can?(:approve_requests) && !own_request?
  def pay?     = can?(:pay_advances) && same_business?(record.user)
  def bulk_pay? = can?(:pay_advances)  # class-level; per-request scoping via policy_scope
  def update?  = own_request? && record.pending?
  def destroy? = false
  def new?     = create?

  # Employees cancel their own pending requests.
  # Authorized reviewers (approve_requests or pay_advances) can cancel pending
  # or approved requests on behalf of the business (e.g. before payroll runs).
  def cancel?
    return false unless record.status.in?(%w[pending approved])
    return true  if own_request? && record.pending?

    (can?(:approve_requests) || can?(:pay_advances)) && same_business?(record.user)
  end

  def create?
    effective_user = record.user || user
    return false unless effective_user.business_id == user.business_id
    return true  if effective_user == user

    # Mirror the on-behalf-of picker: an approver may submit for any employee in
    # their configured scope, resolved most-specific-first
    # (approve_requests → view_requests → view_employees), not just direct reports.
    return false unless can?(:approve_requests)

    EmployeeScope.new(user)
                 .for_permissions(:approve_requests, :view_requests, :view_employees)
                 .exists?(id: effective_user.id)
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.can?(:view_requests) || user.can?(:approve_requests)
        configured = user.scope_for(:view_requests)
        base       = scope.for_business(user.business)
        if configured
          filter_by_data_scope(base, configured)
        else
          managed_ids = EmployeeScope.new(user).relation.select(:id)
          base.where(user_id: user.id).or(base.where(user_id: managed_ids))
        end
      else
        scope.where(user_id: user.id)
      end
    end
  end

  private

  def own_request?
    record.user_id == user.id
  end
end
