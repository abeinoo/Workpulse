# Product availability per warehouse (ProductWarehouseSetting).
#
# record: a ProductWarehouseSetting (an existing pair), a Warehouse (adding a
# product there), or the class (collection gate). Every record check requires
# the user's business AND a warehouse inside the user's inventory warehouse
# scope (User#inventory_warehouse_ids — nil = every warehouse of the business,
# an Array — possibly empty — = exactly those).
#
# Changing availability is its own workflow permission,
# manage_product_availability — manage_products / manage_inventory alone do
# not grant it (narrow operation permissions). Owners pass every can?.
class ProductWarehouseSettingPolicy < ApplicationPolicy
  def show?        = (can?(:view_inventory) || can?(:manage_inventory)) && reachable?
  def manage?      = can?(:manage_product_availability) && reachable?
  def bulk_manage? = can?(:manage_product_availability)
  # The read-only reconciliation report (Phase 2): for the people who decide
  # availability; it lists only the user's reachable warehouses.
  def reconciliation? = can?(:manage_product_availability)

  class Scope < ApplicationPolicy::Scope
    def resolve
      for_accessible_warehouses(scope.where(business_id: user.business_id))
    end
  end

  private

  def reachable?
    warehouse_id, business_id =
      case record
      when ProductWarehouseSetting then [ record.warehouse_id, record.business_id ]
      when Warehouse               then [ record.id, record.business_id ]
      else return false
      end
    return false if business_id.nil? || business_id != user.business_id

    ids = user.inventory_warehouse_ids
    ids.nil? || ids.include?(warehouse_id)
  end
end
