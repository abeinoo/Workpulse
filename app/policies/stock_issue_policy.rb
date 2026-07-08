class StockIssuePolicy < ApplicationPolicy
  def index?   = can?(:view_inventory) || can?(:manage_inventory)
  def show?    = index?
  def create?  = can?(:manage_inventory) || can?(:manage_stock_issues)
  def update?  = create?
  def destroy? = create?
  # A draft (from an in-progress import) has no movements to reverse — voiding
  # it would fabricate a compensating "return" for stock that was never
  # actually taken out. `record` may be the class itself for a bare
  # permission check (e.g. "can this role ever void issues?"), so the
  # draft/posted guard only applies once we have an actual instance.
  def void?
    return false unless create?
    record.is_a?(StockIssue) ? record.posted? : true
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      for_accessible_warehouses(scope.for_business(user.business))
    end
  end
end
