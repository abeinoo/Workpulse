module Inventory
  # Applies a Purchase Request's confirmed advance payments to ONE Goods
  # Receipt created from it. Called from Inventory::GoodsReceiptApproval#approve!
  # — receipt approval is the existing financial event, so this is where an
  # advance is consumed; nothing is applied at receipt creation or at
  # warehouse confirmation.
  #
  # Deterministic rule — oldest advance first, up to the receipt's value:
  #   applied to this receipt = min(unapplied advances, receipt value)
  #   due now                 = receipt value − applied
  # walking advances by confirmed_at, id. Each consumed slice is one
  # FinancialSettlement on the receipt (source_kind purchase_request_advance,
  # funding_source = the advance); no custody or cash moves — that money moved
  # once, at advance confirmation. Because "unapplied" is re-derived from those
  # rows every time, a slice consumed by one receipt can never be consumed by
  # another; voiding a receipt reverses its rows (FinancialSettlementService
  # .reverse_all) and the amount becomes available again.
  #
  # Example: request 242, one advance 100.
  #   receipt #1 (121) → applies 100, due 21
  #   receipt #2 (121) → applies 0,   due 121
  #
  # Concurrency: callers must hold the Purchase Request row lock (receipt
  # approval locks it, as do advance confirm/reverse) before #apply!.
  class PurchaseRequestAdvanceAllocator
    Allocation = Struct.new(:advance, :amount, keyword_init: true)

    attr_reader :receipt

    def initialize(receipt)
      @receipt = receipt
    end

    # What would be (or, once approved, what was) applied to this receipt —
    # computed, never written. Used by the receiving screens before approval.
    def allocations
      @allocations ||= compute
    end

    def applied_total = allocations.sum(&:amount)

    def amount_due
      [ @receipt.total_value - applied_total, 0 ].max
    end

    # For the receiving screens: what WAS applied once the receipt is approved
    # (read from its ledger), otherwise what WILL be applied at approval.
    def receipt_applied_amount
      return @receipt.financial_settlements.advance_applications.sum(:amount) if @receipt.approval_approved?

      applied_total
    end

    def receipt_amount_due
      [ @receipt.total_value - receipt_applied_amount, 0 ].max
    end

    # Posts the allocations as settlement rows on the receipt. Returns the
    # total applied. Must run inside the approval transaction.
    def apply!(actor:)
      allocations.each do |allocation|
        # The settlement row is Finance & Sales' (Inventory::GoodsReceiptPaymentEffects).
        Inventory::GoodsReceiptPaymentEffects.advance_applied(
          receipt:   @receipt,
          advance:   allocation.advance,
          amount:    allocation.amount,
          actor:     actor,
          reference: @receipt.purchase_request.request_number,
          notes:     I18n.t("inventory.purchase_request_advances.application_note",
                            advance: allocation.advance.id, reference: @receipt.purchase_request.request_number)
        )
      end
      applied_total
    end

    private

    def compute
      request = @receipt.purchase_request
      return [] if request.nil? || @receipt.voided?

      # Only what isn't already settled on this receipt can still be covered.
      room = [ @receipt.total_value - @receipt.total_settled_amount, 0 ].max
      return [] unless room.positive?

      request.advances.confirmed.chronological.each_with_object([]) do |advance, result|
        break result unless room.positive?

        take = [ advance.unapplied_amount, room ].min
        next result unless take.positive?

        result << Allocation.new(advance: advance, amount: take)
        room -= take
      end
    end
  end
end
