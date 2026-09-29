# Warehouse → branch supply links. Viewing follows warehouse visibility;
# changing a link is warehouse configuration, so it needs manage_inventory
# (same gate as WarehousePolicy#update?) — and a warehouse-scoped manager may
# only touch links to warehouses they can access.
class WarehouseBranchSupplyPolicy < ApplicationPolicy
  def index?  = can?(:view_inventory) || can?(:manage_inventory)
  def manage? = can?(:manage_inventory)

  # record: the target Warehouse (and, for an existing link, its current one).
  def assign?(warehouse, current_warehouse = nil)
    manage? && accessible?(warehouse) && (current_warehouse.nil? || accessible?(current_warehouse))
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      for_accessible_warehouses(scope.where(business_id: user.business_id))
    end
  end

  private

  def accessible?(warehouse)
    ids = user.inventory_warehouse_ids
    warehouse.business_id == user.business_id && (ids.nil? || ids.include?(warehouse.id))
  end
end
