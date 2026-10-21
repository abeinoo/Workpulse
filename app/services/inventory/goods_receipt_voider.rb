module Inventory
  # Voids a goods receipt whose financial or inventory effects need reversing —
  # either a fully confirmed receipt (stock posted) or one that's approved but
  # not yet confirmed (money already deducted at approval, no stock posted yet).
  #
  # For a confirmed receipt, stock is reversed via the generic
  # Inventory::DocumentVoider (unchanged, still shared with StockIssue/
  # StockTransfer). For an approved-but-unconfirmed receipt, there's no posted
  # inventory movement to reverse (GoodsReceiptPoster never ran), so the
  # receipt is simply marked voided directly.
  #
  # Either way, every settlement still in effect on the receipt is reversed via
  # FinancialSettlementService.reverse_all — each with a new, equal-and-
  # opposite FinancialSettlement row linked to its original (never modifying
  # the original) — plus, for any settlement funded from an employee's custody
  # account, a matching reversing CustodyTransaction so the balance returns to
  # what it was before that payment.
  #
  # A receipt may carry several settlements (partial payments from different
  # sources), some of which may already have been individually reversed via
  # Inventory::GoodsReceiptSettlementReverser. reverse_all only touches
  # originals that are still unreversed, so reversal rows and already-reversed
  # payments are never reversed a second time, and custody is only refunded
  # for the payments actually being reversed here.
  #
  # Everything happens in one transaction: if any reversal fails, the stock
  # reversal (if any) is rolled back too.
  class GoodsReceiptVoider
    include AuditLoggable

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
        # Row lock first, reloading the receipt (BUG-015 / BUG-016): every decision
        # below — confirmed?, voided?, the approval status to cancel — is made on
        # the current row, not a stale copy. A concurrent approval, settlement,
        # reversal or second void (all of which lock the receipt first too) is
        # waited for and then seen; a second void is refused as already voided.
        @receipt.lock!

        if @receipt.confirmed?
          result = Inventory::DocumentVoider.new(@receipt, user: @actor, reason: @reason).call
          raise ActiveRecord::Rollback unless result.ok?
        else
          raise ActiveRecord::Rollback unless void_unconfirmed!
        end

        approval_from = cancel_undecided_approval!

        reverse_settlements!

        metadata = { reason: @reason }
        metadata[:approval_status] = [ approval_from, "cancelled" ] if approval_from
        log_audit(actor: @actor, auditable: @receipt, action: "void", metadata: metadata)

        return Result.new(ok: true, document: @receipt)
      end

      Result.new(ok: false, document: @receipt, error: @receipt.errors.full_messages.to_sentence)
    end

    private

    # Mirrors DocumentVoider's own-voided/blank-reason guards, minus the stock
    # reversal — there's nothing posted yet to reverse.
    def void_unconfirmed!
      if @receipt.voided?
        @receipt.errors.add(:base, :already_voided)
        return false
      end

      reason = @reason.to_s.strip
      if reason.blank?
        @receipt.errors.add(:void_reason, :blank)
        return false
      end

      @receipt.update!(voided_at: Time.current, voided_by: @actor, void_reason: reason)
      true
    end

    # A receipt cancelled before any approval decision (draft / pending_approval)
    # leaves the approval workflow: approval_status → cancelled, in the same
    # transaction as the void, so it never stays "awaiting approval" while its
    # receiving status reads voided. Approved/rejected decisions are kept as
    # history. Returns the previous approval status, or nil when unchanged.
    def cancel_undecided_approval!
      from = @receipt.approval_status
      return nil unless GoodsReceipt::UNDECIDED_APPROVAL_STATUSES.include?(from)

      @receipt.update!(approval_status: "cancelled")
      from
    end

    def reverse_settlements!
      results = FinancialSettlementService.reverse_all(
        settleable: @receipt, actor: @actor,
        notes: I18n.t("inventory.goods_receipts.settlement_reversal_note", reference: @receipt.receipt_number)
      )
      failed = results.find { |r| !r.ok? }
      raise ActiveRecord::RecordInvalid, failed.settlement if failed

      results.each do |result|
        reversal = result.settlement
        reverse_custody_transaction!(reversal) if reversal.funding_source.is_a?(CustodyAccount)
      end
    end

    # Credits back the custody side of one reversal settlement, linked to it.
    def reverse_custody_transaction!(reversal)
      account = reversal.funding_source
      account.with_lock do
        account.custody_transactions.create!(
          business:             account.business,
          txn_type:             "inventory_purchase_reversal",
          amount:               -reversal.amount,
          source:               @receipt,
          financial_settlement: reversal,
          created_by:           @actor,
          notes:                I18n.t("finance.custody.inventory_purchase_reversal_note", reference: @receipt.receipt_number)
        )
        account.refresh_balance!
      end
    end
  end
end
