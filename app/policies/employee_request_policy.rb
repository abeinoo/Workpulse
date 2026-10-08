class EmployeeRequestPolicy < ApplicationPolicy
  def index?   = true  # scope handles isolation
  def show?    = can?(:view_requests) || can?(:approve_requests) || own_request?
  # Self-approval is blocked: an approver may not approve or reject a request they
  # themselves submitted — another authorized approver must review it. Gates the UI
  # buttons (views read policy.approve?/reject?) and the controller `authorize`.
  # The requester must also be inside the approver's scope (SEC-P9-1) — resolved
  # like create? (approve_requests → view_requests → view_employees), so a
  # narrower approve_requests scope is not widened by view_requests.
  def approve? = can?(:approve_requests) && !own_request? && reviewable_employee?
  def reject?  = approve?
  # Reviewer-only validation details on the show page (attendance-window check,
  # shift span, resulting work duration, duration warnings, confirmation). Same
  # people who may approve — independent of status, so the details stay visible
  # to reviewers after approval. Requesters never see them.
  def review_details? = can?(:approve_requests) && !own_request?
  def pay?     = can?(:pay_advances) && same_business?(record.user)
  def bulk_pay? = can?(:pay_advances)  # class-level; per-request scoping via policy_scope
  def update?  = own_request? && record.pending?
  def destroy? = false
  def new?     = create?

  # Employees cancel their own pending requests.
  # Authorized reviewers can cancel pending or approved requests on behalf of the
  # business (e.g. before payroll runs):
  # * approve_requests holders — any request type, their own or an employee in
  #   their approver scope (SEC-P9-1);
  # * pay_advances holders — salary advance requests only, their own or an
  #   employee in their pay_advances scope. It never reaches permissions or punch
  #   corrections, nor widens the approve_requests scope.
  def cancel?
    return false unless record.status.in?(%w[pending approved])
    return true  if own_request? && record.pending?
    return false unless same_business?(record.user)

    approver_cancel? || advance_payer_cancel?
  end

  def create?
    effective_user = record.user || user
    return false unless effective_user.business_id == user.business_id
    return true  if effective_user == user

    # Mirror the on-behalf-of picker: an approver may submit for any employee in
    # their configured scope, resolved most-specific-first
    # (approve_requests → view_requests → view_employees), not just direct reports.
    return false unless can?(:approve_requests)

    in_approver_scope?(effective_user.id)
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

  def reviewable_employee? = in_approver_scope?(record.user_id)

  def in_approver_scope?(user_id) = employee_in_scope?(user_id, :approve_requests, :view_requests, :view_employees)

  def approver_cancel? = can?(:approve_requests) && (own_request? || reviewable_employee?)

  def advance_payer_cancel?
    record.salary_advance? && can?(:pay_advances) &&
      (own_request? || employee_in_scope?(record.user_id, :pay_advances, :view_requests, :view_employees))
  end

  # EmployeeScope resolves the first permission with a configured data scope
  # (most-specific first), else the manager hierarchy.
  def employee_in_scope?(user_id, *permissions)
    EmployeeScope.new(user).for_permissions(*permissions).exists?(id: user_id)
  end
end
