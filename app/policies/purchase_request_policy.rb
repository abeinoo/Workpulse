class PurchaseRequestPolicy < ApplicationPolicy
  def index?   = can?(:view_inventory) || can?(:manage_inventory)
  def show?    = index?
  def create?  = can?(:manage_inventory) || can?(:create_purchase_requests)
  def destroy? = create? &&
                 (!record.is_a?(PurchaseRequest) || record.draft?)

  # Only a draft may be edited — enforced here (not just hidden in the UI),
  # and re-checked again, race-safely, inside Inventory::PurchaseRequestUpdater.
  def update? = create? &&
                (!record.is_a?(PurchaseRequest) || record.draft?)

  def submit_for_approval? = create? &&
                              (!record.is_a?(PurchaseRequest) || record.draft?)

  def approve? = (can?(:manage_inventory) || can?(:approve_purchase_requests)) &&
                 (!record.is_a?(PurchaseRequest) || record.pending_approval?)
  def reject?  = approve?

  # Only while nothing has been received yet — once receiving has started,
  # the commitment is real and the request can no longer be walked back.
  def cancel? = create? &&
                (!record.is_a?(PurchaseRequest) || record.approved?)

  # "إغلاق المتبقي" — closing off the outstanding quantity is a purchasing
  # decision of the same weight as approve/reject, so it reuses that same
  # permission tier rather than the lighter create_purchase_requests one.
  def close_remaining? = (can?(:manage_inventory) || can?(:approve_purchase_requests)) &&
                        (!record.is_a?(PurchaseRequest) || record.partially_received?)

  # Gates the "إنشاء إذن استلام" action/route — reuses the SAME permission as
  # actually creating a GoodsReceipt (create_goods_receipts), per the existing
  # GoodsReceipt authorization model; this is a GoodsReceipt-creation action,
  # not a purchase-request one.
  def create_goods_receipt? = (can?(:manage_inventory) || can?(:create_goods_receipts)) &&
                              (!record.is_a?(PurchaseRequest) || record.receivable?)

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.for_business(user.business)
    end
  end
end
