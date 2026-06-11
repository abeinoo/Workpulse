class WarehousePolicy < ApplicationPolicy
  def index?   = can?(:view_inventory) || can?(:manage_inventory)
  def show?    = index?
  def create?  = can?(:manage_inventory)
  def update?  = create?
  def destroy? = create?

  class Scope < ApplicationPolicy::Scope
    def resolve
      for_accessible_warehouses(scope.for_business(user.business), column: :id)
    end
  end
end
