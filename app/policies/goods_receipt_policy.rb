class GoodsReceiptPolicy < ApplicationPolicy
  def index?   = can?(:view_inventory) || can?(:manage_inventory)
  def show?    = index?
  def create?  = can?(:manage_inventory) || can?(:manage_stock_receipts)
  def update?  = create?
  def destroy? = create?
  def confirm? = can?(:manage_inventory) || can?(:confirm_goods_receipts)
  def void?    = create? && (!record.is_a?(GoodsReceipt) || record.confirmed?)

  class Scope < ApplicationPolicy::Scope
    def resolve
      for_accessible_warehouses(scope.for_business(user.business))
    end
  end
end
