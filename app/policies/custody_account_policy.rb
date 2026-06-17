class CustodyAccountPolicy < ApplicationPolicy
  # Any finance user can reach the Employee Balances page; the scope enforces
  # what they see (own account only vs. all).
  def index?   = can?(:view_employee_balances) || can?(:manage_employee_balances) ||
                 can?(:view_expenses) || can?(:create_expenses)
  def show?    = (can?(:view_employee_balances) && same_business?) || holder?
  def new?     = can?(:manage_employee_balances)
  # A branch-attributed custody account must sit in the manager's scope; a
  # branch-less (user-held only) account isn't branch-restricted.
  def create?  = can?(:manage_employee_balances) && same_business? &&
                 branch_within_scope?(record.branch_id, :view_employee_balances, allow_nil: true)
  def update?  = create?
  def destroy? = update?

  class Scope < ApplicationPolicy::Scope
    def resolve
      base = scope.for_business(user.business)

      # Employees without balance permissions see only their own account.
      unless user.can?(:view_employee_balances) || user.can?(:manage_employee_balances)
        return base.where(user_id: user.id)
      end

      return base if user.owner?

      scope_type = user.scope_for(:view_employee_balances) || :default
      filter_by_branch_scope(base, scope_type, own_column: :user_id)
    end
  end

  private

  def holder?
    record.respond_to?(:user_id) && record.user_id == user.id
  end
end
