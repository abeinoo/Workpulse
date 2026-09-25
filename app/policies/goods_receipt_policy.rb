class GoodsReceiptPolicy < ApplicationPolicy
  def index?   = can?(:view_inventory) || can?(:manage_inventory)
  def show?    = index?
  def create?  = can?(:manage_inventory) || can?(:create_goods_receipts)
  def update?  = create? && not_voided? &&
                 (!record.is_a?(GoodsReceipt) || %w[draft rejected].include?(record.approval_status))
  def destroy? = create?
  def submit_for_approval? = update?

  def approve? = (can?(:manage_inventory) || can?(:approve_goods_receipts)) && not_voided? &&
                 (!record.is_a?(GoodsReceipt) || record.approval_pending_approval?)
  def reject?  = approve?

  def confirm? = (can?(:manage_inventory) || can?(:confirm_goods_receipts)) && not_voided? &&
                 (!record.is_a?(GoodsReceipt) || (record.draft? && record.approval_approved?))

  # A receipt can be voided once its financial effects exist (approved,
  # possibly not yet confirmed) or once it's fully confirmed — either way
  # there's something (money and/or stock) to reverse. Voiding is terminal:
  # an already-voided receipt can never be voided again or re-enter the
  # workflow, so every action above (and this one) is gated on not_voided?.
  def void?    = (can?(:manage_inventory) || can?(:void_goods_receipts)) && not_voided? &&
                 (!record.is_a?(GoodsReceipt) || record.confirmed? || record.approval_approved?)

  # Requester self-service cancel — only while nothing has been posted yet
  # (no stock movement, no settlement/custody deduction: those only happen at
  # approval/confirmation). Once approved or confirmed, only #void? applies —
  # that path reverses real financial/inventory effects and is manager-gated.
  # Same permission as create/edit, since this policy has no per-user
  # ownership concept (draft receipts are editable by anyone with
  # create_goods_receipts, not just their creator).
  def cancel?  = (can?(:manage_inventory) || can?(:create_goods_receipts)) && not_voided? &&
                 (!record.is_a?(GoodsReceipt) || %w[draft pending_approval].include?(record.approval_status))

  # Recording a later payment against an approved receipt's outstanding amount
  # (Inventory::GoodsReceiptSettlementRecorder). Same people who make the
  # receipt's financial decision at approval — no employee-balance permission
  # is needed to pay from someone's custody; the service enforces the custody
  # rules (active account, sufficient balance). Independent of receiving status.
  def settle? = (can?(:manage_inventory) || can?(:approve_goods_receipts)) && not_voided? &&
                (!record.is_a?(GoodsReceipt) ||
                  (record.approval_approved? && record.remaining_settlement_amount.positive?))

  # Reversing ONE recorded settlement (Inventory::GoodsReceiptSettlementReverser)
  # — the same reversing-entry mechanism as a void, so it's gated like #void?.
  def reverse_settlement? = (can?(:manage_inventory) || can?(:void_goods_receipts)) && not_voided? &&
                            (!record.is_a?(GoodsReceipt) || record.approval_approved?)

  class Scope < ApplicationPolicy::Scope
    def resolve
      for_accessible_warehouses(scope.for_business(user.business))
    end
  end

  private

  # Voided is a terminal state (Voidable#voided_at, independent of the
  # status/approval_status enums) — no workflow action is ever permitted on
  # a voided receipt, regardless of what those enums still say.
  def not_voided?
    !record.is_a?(GoodsReceipt) || !record.voided?
  end
end
