class StockAdjustmentPolicy < ApplicationPolicy
  def index?   = can?(:view_inventory) || can?(:manage_inventory)
  def show?    = index?
  def create?  = can?(:manage_inventory)
  def update?  = create?
  def destroy? = create?
  # A stock-count adjustment is reversed only by reopening its count
  # (Inventory::StockCountReopener) — voiding it alone would leave the count
  # "approved" with no stock effect.
  def void?    = create? && (!record.is_a?(StockAdjustment) || record.stock_count_id.nil?)

  class Scope < ApplicationPolicy::Scope
    def resolve
      for_accessible_warehouses(scope.for_business(user.business))
    end
  end
end
