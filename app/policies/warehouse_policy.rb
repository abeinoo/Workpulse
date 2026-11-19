class WarehousePolicy < ApplicationPolicy
  def index?   = can?(:view_inventory) || can?(:manage_inventory)
  def show?    = index?

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
  def classify? = create?

  # Unchanged: editing and deleting stay a manage_inventory action, on a
  # warehouse the user can reach (records are loaded through Scope).
  def update?  = can?(:manage_inventory)
  def destroy? = update?

  class Scope < ApplicationPolicy::Scope
    def resolve
      for_accessible_warehouses(scope.for_business(user.business), column: :id)
    end
  end
end
