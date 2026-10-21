module Inventory
  # Reverses ONE settlement on a goods receipt (e.g. a payment recorded from
  # the wrong employee's custody), leaving the receipt itself and every other
  # settlement untouched. Uses the same reversing-entry pattern as
  # Inventory::GoodsReceiptVoider:
  #   - a new, equal-and-opposite FinancialSettlement linked to the original
  #     (FinancialSettlementService.reverse) — the original is never modified;
  #   - for a custody-funded payment, an "inventory_purchase_reversal"
  #     CustodyTransaction crediting the same account back.
  # Remaining amount and financial_status re-derive from the ledger. Both rows
  # (and the settlement lookup and refusals) are Finance & Sales', through
  # Inventory::GoodsReceiptPaymentEffects (Batch S).
  #
  # A reason is mandatory. A settlement can be reversed at most once (service
  # guard + unique index on reverses_settlement_id). Voided receipts are out of
  # scope — voiding already reverses everything still in effect.
  class GoodsReceiptSettlementReverser
    include AuditLoggable

    Result = Struct.new(:ok, :settlement, :receipt, :error, keyword_init: true) { def ok? = ok }

    def initialize(goods_receipt_id:, settlement_id:, actor:, reason:)
      @goods_receipt_id = goods_receipt_id
      @settlement_id    = settlement_id
      @actor            = actor
      @reason           = reason.to_s.strip
    end

    def call
      @receipt = GoodsReceipt.where(business_id: @actor.business_id).find(@goods_receipt_id)
      return err(t("errors.reason_required")) if @reason.blank?

      reversal = nil
      ActiveRecord::Base.transaction do
        @receipt.lock!
        return err(t("errors.receipt_voided")) if @receipt.voided?

        # Finance & Sales finds the settlement under a row lock (after the
        # receipt; RecordNotFound when it is not this receipt's), refuses a
        # reversal / reversed original or an advance application, and otherwise
        # posts the reversal and credits custody.
        outcome = Inventory::GoodsReceiptPaymentEffects.reverse_settlement(
          receipt: @receipt, settlement_id: @settlement_id, actor: @actor, reason: @reason
        )
        return err(I18n.t("financial_settlements.errors.already_reversed")) if outcome.status == :already_reversed
        # Advance applications aren't payments to undo one by one — they are
        # released only by voiding the receipt (see PurchaseRequestAdvanceAllocator).
        return err(t("errors.advance_application_not_reversible")) if outcome.status == :advance_application

        reversal = outcome.settlement

        log_audit(actor: @actor, auditable: @receipt, action: "reverse_settlement",
                  metadata: { settlement_id: outcome.settlement_id, reversal_id: outcome.reversal_id,
                              amount: outcome.amount.to_s, source_kind: outcome.source_kind, reason: @reason,
                              custody_account_id: outcome.funding_source_id,
                              supplier_id: @receipt.supplier_id })
      end

      Result.new(ok: true, settlement: reversal, receipt: @receipt)
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.to_sentence)
    end

    private

    def t(key, **)
      I18n.t("inventory.goods_receipts.settlements.#{key}", **)
    end

    def err(message)
      Result.new(ok: false, receipt: @receipt, error: message)
    end
  end
end
