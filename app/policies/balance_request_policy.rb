class BalanceRequestPolicy < ApplicationPolicy
  def index?  = can?(:view_employee_balances) || can?(:create_balance_requests)
  def show?   = (can?(:view_employee_balances) && same_business?) || own_request?

  def new?    = can?(:create_balance_requests)
  def create? = can?(:create_balance_requests) && same_business?

  def update?  = same_business? && record.draft? && (can?(:manage_employee_balances) || own_request?)
  def destroy? = same_business? && record.draft? && (can?(:manage_employee_balances) || own_request?)

  def submit?
    same_business? && record.draft? &&
      (can?(:create_balance_requests) || can?(:manage_employee_balances))
  end

  def approve? = can?(:approve_balance_requests) && same_business? && record.pending_approval? &&
                 (user.owner? || !own_request?)
  def reject?  = approve?

  def mark_paid? = can?(:approve_balance_requests) && same_business? && record.approved?

  # Creators cancel draft / pending requests they own.
  # Finance managers / approvers can also cancel approved requests.
  def cancel?
    return false unless same_business? && record.status.in?(%w[draft pending_approval approved])
    return true  if own_request? && !record.approved?

    can?(:manage_employee_balances) || can?(:approve_balance_requests)
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user.can?(:view_employee_balances) || user.can?(:create_balance_requests)

      base = scope.for_business(user.business)
      return base if user.owner?

      scope_type = user.scope_for(:view_employee_balances) || :default
      return base if scope_type.to_s == "business"

      branch_ids = BranchScope.new(user).for_scope(scope_type)
      base.where(branch_id: branch_ids).or(base.where(created_by: user))
    end
  end

  private

  def own_request?
    record.created_by_id == user.id
  end
end
