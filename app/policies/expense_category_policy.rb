class ExpenseCategoryPolicy < ApplicationPolicy
  # Catalog is business-global (not branch-scoped). Readable by anyone who can see
  # or create expenses (they need it to populate pickers); managed by the
  # dedicated catalog permission.
  def index?   = can?(:view_expenses) || can?(:create_expenses) || can?(:manage_expense_categories)
  def show?    = index?
  def create?  = can?(:manage_expense_categories)
  def update?  = create?
  def destroy? = create?

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.for_business(user.business)
    end
  end
end
