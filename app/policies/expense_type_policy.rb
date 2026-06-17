class ExpenseTypePolicy < ApplicationPolicy
  def index?   = can?(:view_expenses) || can?(:create_expenses) || can?(:manage_expense_types)
  def show?    = index?
  def create?  = can?(:manage_expense_types)
  def update?  = create?
  def destroy? = create?

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.for_business(user.business)
    end
  end
end
