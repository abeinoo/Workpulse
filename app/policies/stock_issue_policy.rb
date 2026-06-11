class StockIssuePolicy < ApplicationPolicy
  def index?   = can?(:view_inventory) || can?(:manage_inventory)
  def show?    = index?
  def create?  = can?(:manage_inventory) || can?(:manage_stock_issues)
  def update?  = create?
  def destroy? = create?
  def void?    = create?

  class Scope < ApplicationPolicy::Scope
    def resolve
      for_accessible_warehouses(scope.for_business(user.business))
    end
  end
end
