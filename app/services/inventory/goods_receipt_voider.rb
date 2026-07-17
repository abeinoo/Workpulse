module Inventory
  # Voids a confirmed goods receipt via the generic Inventory::DocumentVoider
  # (stock reversal, unchanged, still shared with StockIssue/StockTransfer),
  # then reverses every settlement recorded against the receipt via
  # FinancialSettlementService.reverse_all — each with a new,
  # equal-and-opposite FinancialSettlement row (never modifying the original)
  # — plus, for any settlement funded from an employee's custody account, a
  # matching reversing CustodyTransaction so the balance returns to what it
  # was before confirmation.
  #
  # A receipt can only be voided once (Inventory::DocumentVoider enforces
  # this), so at the point this runs every existing settlement is an original
  # — there's nothing to guard against double-reversal.
  #
  # Everything happens in one transaction: if any reversal fails, the stock
  # reversal is rolled back too.
  class GoodsReceiptVoider
    Result = Struct.new(:ok, :document, :error, keyword_init: true) do
      def ok? = ok
    end

    def initialize(goods_receipt_id:, actor:, reason:)
      @goods_receipt_id = goods_receipt_id
      @actor            = actor
      @reason           = reason
    end

    def call
      @receipt = GoodsReceipt.where(business_id: @actor.business_id).find(@goods_receipt_id)

      ActiveRecord::Base.transaction do
        result = Inventory::DocumentVoider.new(@receipt, user: @actor, reason: @reason).call
        raise ActiveRecord::Rollback unless result.ok?

        reverse_settlements!

        return Result.new(ok: true, document: @receipt)
      end

      Result.new(ok: false, document: @receipt, error: @receipt.errors.full_messages.to_sentence)
    end

    private

    def reverse_settlements!
      originals = @receipt.financial_settlements.to_a

      results = FinancialSettlementService.reverse_all(
        settleable: @receipt, actor: @actor,
        notes: I18n.t("inventory.goods_receipts.settlement_reversal_note", reference: @receipt.receipt_number)
      )
      failed = results.find { |r| !r.ok? }
      raise ActiveRecord::RecordInvalid, failed.settlement if failed

      originals.each do |settlement|
        reverse_custody_transaction!(settlement) if settlement.funding_source.is_a?(CustodyAccount)
      end
    end

    def reverse_custody_transaction!(settlement)
      account = settlement.funding_source
      account.with_lock do
        account.custody_transactions.create!(
          business:   account.business,
          txn_type:   "inventory_purchase_reversal",
          amount:     settlement.amount,
          source:     @receipt,
          created_by: @actor,
          notes:      I18n.t("finance.custody.inventory_purchase_reversal_note", reference: @receipt.receipt_number)
        )
        account.refresh_balance!
      end
    end
  end
end
