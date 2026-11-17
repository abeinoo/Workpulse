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

  # The PR page's item editor (add / edit / delete lines) before approval: a
  # draft by whoever may edit it (#update?), a request pending approval by its
  # reviewers only. Never after approval. Re-checked race-safely (state) by
  # Inventory::PurchaseRequestUpdater.
  def edit_items?
    return create? || reviewer? unless record.is_a?(PurchaseRequest)
    return update? if record.draft?

    record.pending_approval? && reviewer?
  end

  def submit_for_approval? = create? &&
                              (!record.is_a?(PurchaseRequest) || record.draft?)

  # A request of a warehouse the user cannot reach is never approved or
  # rejected by them (D5) — checked against Scope, the one definition.
  def approve? = (can?(:manage_inventory) || can?(:approve_purchase_requests)) &&
                 (!record.is_a?(PurchaseRequest) || (record.pending_approval? && reachable?))
  def reject?  = approve?

  # Class-level gate for "اعتماد الطلبات المحددة" — the same permission as a
  # single approval. Per-request state (pending_approval, self-approval) is
  # re-checked under lock by Inventory::PurchaseRequestBulkApproval.
  def bulk_approve? = can?(:manage_inventory) || can?(:approve_purchase_requests)

  # Only while nothing has been received yet — once receiving has started,
  # the commitment is real and the request can no longer be walked back.
  def cancel? = create? &&
                (!record.is_a?(PurchaseRequest) || record.approved?)

  # "إغلاق المتبقي" — closing off the outstanding quantity is a purchasing
  # decision of the same weight as approve/reject, so it reuses that same
  # permission tier rather than the lighter create_purchase_requests one.
  def close_remaining? = (can?(:manage_inventory) || can?(:approve_purchase_requests)) &&
                        (!record.is_a?(PurchaseRequest) || record.partially_received?)

  # "تعيين الموظف المسؤول" on an approved / receivable request (a draft changes
  # it through the edit form). Same tier as approval. Whether advances still
  # lock it is re-checked under lock by Inventory::PurchaseRequestResponsibleAssigner.
  def assign_responsible_employee? = (can?(:manage_inventory) || can?(:approve_purchase_requests)) &&
                                     (!record.is_a?(PurchaseRequest) || record.receivable?)

  # Gates the "إنشاء إذن استلام" action/route — reuses the SAME permission as
  # actually creating a GoodsReceipt (create_goods_receipts), per the existing
  # GoodsReceipt authorization model; this is a GoodsReceipt-creation action,
  # not a purchase-request one.
  def create_goods_receipt? = (can?(:manage_inventory) || can?(:create_goods_receipts)) &&
                              (!record.is_a?(PurchaseRequest) || record.receivable?)

  private

  def reviewer? = can?(:manage_inventory) || can?(:approve_purchase_requests)

  # The persisted request is within the user's Scope (business + warehouses).
  def reachable?
    record.persisted? && Scope.new(user, PurchaseRequest).resolve.exists?(id: record.id)
  end

  public

  # Warehouse scoping (D5): a user restricted to some warehouses sees — and so
  # can act on — only the purchase requests of those warehouses; nil from
  # inventory_warehouse_ids (owner, company-wide access) keeps the whole
  # business; an empty set sees none, never the whole business.
  #
  # A request's warehouse is its warehouse_id. A legacy request (no
  # warehouse_id; each line named its own source warehouse) is reachable only
  # when it has lines and EVERY line's source warehouse is reachable — a line
  # with no warehouse at all fails closed.
  class Scope < ApplicationPolicy::Scope
    def resolve
      relation = scope.for_business(user.business)
      ids = user.inventory_warehouse_ids
      return relation if ids.nil?
      return relation.none if ids.empty?

      lines = PurchaseRequestItem.where("purchase_request_items.purchase_request_id = purchase_requests.id")
      outside = lines.where("purchase_request_items.source_warehouse_id IS NULL OR " \
                            "purchase_request_items.source_warehouse_id NOT IN (?)", ids)
      legacy = relation.where(warehouse_id: nil).where(lines.arel.exists).where.not(outside.arel.exists)

      relation.where(warehouse_id: ids).or(legacy)
    end
  end
end
