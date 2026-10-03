module Inventory
  # Reverses ONE settlement on a goods receipt (e.g. a payment recorded from
  # the wrong employee's custody), leaving the receipt itself and every other
  # settlement untouched. Uses the same reversing-entry pattern as
  # Inventory::GoodsReceiptVoider:
  #   - a new, equal-and-opposite FinancialSettlement linked to the original
  #     (FinancialSettlementService.reverse) — the original is never modified;
  #   - for a custody-funded payment, an "inventory_purchase_reversal"
  #     CustodyTransaction crediting the same account back.
  # Remaining amount and financial_status re-derive from the ledger.
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

        original = @receipt.financial_settlements.lock.find(@settlement_id)
        return err(I18n.t("financial_settlements.errors.already_reversed")) if original.reversal? || original.reversed?
        # Advance applications aren't payments to undo one by one — they are
        # released only by voiding the receipt (see PurchaseRequestAdvanceAllocator).
        return err(t("errors.advance_application_not_reversible")) if original.advance_application?

        result = FinancialSettlementService.reverse(settlement: original, actor: @actor, notes: @reason)
        raise ActiveRecord::RecordInvalid, result.settlement unless result.ok?

        reversal = result.settlement
        credit_custody!(original, reversal) if original.funding_source.is_a?(CustodyAccount)

        log_audit(actor: @actor, auditable: @receipt, action: "reverse_settlement",
                  metadata: { settlement_id: original.id, reversal_id: reversal.id, amount: original.amount.to_s,
                              source_kind: original.source_kind, reason: @reason,
                              custody_account_id: original.funding_source_id,
                              supplier_id: @receipt.supplier_id })
      end

      Result.new(ok: true, settlement: reversal, receipt: @receipt)
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.to_sentence)
    end

    private

    def credit_custody!(original, reversal)
      account = original.funding_source
      account.with_lock do
        account.custody_transactions.create!(
          business:             account.business,
          txn_type:             "inventory_purchase_reversal",
          amount:               original.amount,
          source:               @receipt,
          financial_settlement: reversal,
          created_by:           @actor,
          notes:                I18n.t("finance.custody.inventory_settlement_reversal_note",
                                       reference: @receipt.receipt_number, settlement: original.id, reason: @reason)
        )
        account.refresh_balance!
      end
    end

    def t(key, **)
      I18n.t("inventory.goods_receipts.settlements.#{key}", **)
    end

    def err(message)
      Result.new(ok: false, receipt: @receipt, error: message)
    end
  end
end
