module Inventory
  # The single entry point to confirm (receive into the warehouse) a draft
  # goods receipt: posts its stock movements. Purely an inventory event — it
  # never touches custody balances, settlements, or any other funding source.
  # The financial event already happened at approval time
  # (Inventory::GoodsReceiptApproval#approve!); confirmation only requires
  # that the receipt has already been approved.
  class GoodsReceiptConfirmationService
    include AuditLoggable

    Result = Struct.new(:ok, :receipt, :error, keyword_init: true) do
      def ok? = ok
    end

    def initialize(goods_receipt_id:, actor:)
      @goods_receipt_id = goods_receipt_id
      @actor            = actor
    end

    def call
      @receipt = GoodsReceipt.where(business_id: @actor.business_id).find(@goods_receipt_id)

      @receipt.with_lock do
        return already_processed_error if @receipt.voided?
        return already_processed_error unless @receipt.draft?
        return not_approved_error unless @receipt.approval_approved?

        poster_result = GoodsReceiptPoster.new(@receipt).call
        raise ActiveRecord::RecordInvalid, @receipt unless poster_result.ok?

        @receipt.status       = "confirmed"
        @receipt.confirmed_at = Time.current
        @receipt.confirmed_by = @actor
        @receipt.save!

        log_audit(actor: @actor, auditable: @receipt, action: "confirm",
                  changes: { status: %w[draft confirmed] })
      end

      Result.new(ok: true, receipt: @receipt)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, receipt: @receipt, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def already_processed_error
      Result.new(ok: false, receipt: @receipt,
                error: I18n.t("inventory.goods_receipts.errors.already_processed"))
    end

    def not_approved_error
      Result.new(ok: false, receipt: @receipt,
                error: I18n.t("inventory.goods_receipts.errors.not_approved"))
    end
  end
end
