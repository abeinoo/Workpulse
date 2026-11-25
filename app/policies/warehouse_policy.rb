class WarehousePolicy < ApplicationPolicy
  def index?   = can?(:view_inventory) || can?(:manage_inventory)
  # The system transit warehouse is never shown, edited, classified or
  # removed as a warehouse (it is left out of Scope too).
  def show?    = index? && operational_record?

  # Creating a warehouse is company-wide inventory structure (D4): only a
  # business owner or a holder of access_all_warehouses may do it — on top of
  # manage_inventory. manage_inventory alone, warehouse assignments, or a
  # branch- / area-manager relationship never suffice. (can? is true for an
  # owner, so owners pass both checks.) Branch warehouses of sales branches are
  # provisioned by the branch lifecycle, not through this gate.
  def create?  = can?(:manage_inventory) && can?(:access_all_warehouses)

  # Classifying an unclassified warehouse (kind NULL -> central / branch) is
  # the same company-wide structural decision as creating one (D4). The record
  # must also be reachable (it is loaded through Scope).
  def classify? = create? && operational_record?

  # Unchanged: editing and deleting stay a manage_inventory action, on a
  # warehouse the user can reach (records are loaded through Scope).
  def update?  = can?(:manage_inventory) && operational_record?
  def destroy? = update?

  class Scope < ApplicationPolicy::Scope
    def resolve
      # Never the system transit warehouse (Warehouse.operational).
      for_accessible_warehouses(scope.for_business(user.business).operational, column: :id)
    end
  end

  private

  # `record` may be the class itself for a bare permission check.
  def operational_record? = !record.is_a?(Warehouse) || record.operational?
end
