class StockTransferPolicy < ApplicationPolicy
  def index?   = can?(:view_inventory) || can?(:manage_inventory)
  def show?    = index?
  def create?  = can?(:manage_inventory) || can?(:manage_stock_transfers)
  def update?  = create?
  def destroy? = create?
  def void?    = create?

  class Scope < ApplicationPolicy::Scope
    def resolve
      relation = scope.for_business(user.business)
      ids = user.inventory_warehouse_ids
      return relation if ids.nil?

      # A scoped user sees a transfer if EITHER endpoint is one of their warehouses.
      relation.where(source_warehouse_id: ids).or(relation.where(destination_warehouse_id: ids))
    end
  end
end
