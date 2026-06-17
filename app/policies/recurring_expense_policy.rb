class RecurringExpensePolicy < ApplicationPolicy
  def index?   = can?(:view_expenses) || can?(:manage_recurring_expenses)
  def show?    = index? && same_business?
  def new?     = can?(:manage_recurring_expenses)
  def create?  = can?(:manage_recurring_expenses) && same_business? &&
                 branches_within_scope?(write_branch_ids, :manage_recurring_expenses, :view_expenses)
  def update?   = create?
  def destroy?  = update?
  # Generating a pending expense requires the same write-scope as creating the
  # template (manage_recurring_expenses + target branch in scope).
  def generate? = create?

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user.can?(:view_expenses) || user.can?(:manage_recurring_expenses)

      base = scope.for_business(user.business)
      return base if user.owner?

      scope_type = user.scope_for(:view_expenses) || :default
      filter_by_branch_scope(base, scope_type)
    end
  end

  private

  def write_branch_ids
    allocs = record.recurring_expense_allocations.reject(&:marked_for_destruction?)
    return allocs.map(&:branch_id) if allocs.any?

    record.branch_id ? [ record.branch_id ] : []
  end
end
