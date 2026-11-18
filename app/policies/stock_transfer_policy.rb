class StockTransferPolicy < ApplicationPolicy
  def index?   = can?(:view_inventory) || can?(:manage_inventory)
  def show?    = index?
  def create?  = can?(:manage_inventory) || can?(:manage_stock_transfers)
  def update?  = create?
  def destroy? = create?

  # Voiding posts movements into BOTH warehouses (out of the destination, back
  # into the source), so the user must have access to both — not just to the
  # one endpoint that made the transfer visible to them (see Scope). The class
  # gate (record is the StockTransfer class) checks the permission only.
  def void?
    return false unless create?
    return true unless record.is_a?(StockTransfer)

    both_warehouses_accessible?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      relation = scope.for_business(user.business)
      ids = user.inventory_warehouse_ids
      return relation if ids.nil?

      # A scoped user sees a transfer if EITHER endpoint is one of their warehouses.
      relation.where(source_warehouse_id: ids).or(relation.where(destination_warehouse_id: ids))
    end
  end

  private

  # nil from inventory_warehouse_ids = every warehouse of the user's business
  # (unchanged here); otherwise both endpoints must be among the user's ids.
  def both_warehouses_accessible?
    return false unless record.business_id == user.business_id

    ids = user.inventory_warehouse_ids
    return true if ids.nil?

    ids.include?(record.source_warehouse_id) && ids.include?(record.destination_warehouse_id)
  end
end
