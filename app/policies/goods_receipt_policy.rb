class GoodsReceiptPolicy < ApplicationPolicy
  def index?   = can?(:view_inventory) || can?(:manage_inventory)
  def show?    = index?
  def create?  = can?(:manage_inventory) || can?(:create_goods_receipts)
  def update?  = create? && (!record.is_a?(GoodsReceipt) || %w[draft rejected].include?(record.approval_status))
  def destroy? = create?
  def submit_for_approval? = update?

  def approve? = (can?(:manage_inventory) || can?(:approve_goods_receipts)) &&
                 (!record.is_a?(GoodsReceipt) || record.approval_pending_approval?)
  def reject?  = approve?

  def confirm? = (can?(:manage_inventory) || can?(:confirm_goods_receipts)) &&
                 (!record.is_a?(GoodsReceipt) || (record.draft? && record.approval_approved?))

  def void?    = (can?(:manage_inventory) || can?(:void_goods_receipts)) &&
                 (!record.is_a?(GoodsReceipt) || record.confirmed?)

  class Scope < ApplicationPolicy::Scope
    def resolve
      for_accessible_warehouses(scope.for_business(user.business))
    end
  end
end
