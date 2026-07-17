module Inventory
  # The single entry point to confirm a draft goods receipt: posts its stock
  # movements and, if it's funded from an employee's custody account, validates
  # and deducts the balance — all inside one transaction, so a mid-way failure
  # (e.g. insufficient balance) leaves no stock posted and no funds moved.
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

        account = nil
        if @receipt.employee_custody_funded?
          account = @receipt.funding_source
          account.with_lock do
            return insufficient_balance_error if account.computed_balance < @receipt.total_value
          end
        end

        poster_result = GoodsReceiptPoster.new(@receipt).call
        raise ActiveRecord::RecordInvalid, @receipt unless poster_result.ok?

        post_custody_deduction(account) if account

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

    def post_custody_deduction(account)
      settlement_result = FinancialSettlementService.create(
        settleable:     @receipt,
        funding_source: account,
        amount:         @receipt.total_value,
        actor:          @actor,
        notes:          I18n.t("finance.custody.inventory_purchase_note", reference: @receipt.receipt_number)
      )
      raise ActiveRecord::RecordInvalid, settlement_result.settlement unless settlement_result.ok?

      account.custody_transactions.create!(
        business:       account.business,
        txn_type:       "inventory_purchase",
        amount:         -@receipt.total_value,
        source:         @receipt,
        created_by:     @actor,
        notes:          I18n.t("finance.custody.inventory_purchase_note", reference: @receipt.receipt_number)
      )
      account.refresh_balance!
    end

    def insufficient_balance_error
      Result.new(ok: false, receipt: @receipt,
                error: I18n.t("inventory.goods_receipts.errors.insufficient_custody_balance"))
    end

    def already_processed_error
      Result.new(ok: false, receipt: @receipt,
                error: I18n.t("inventory.goods_receipts.errors.already_processed"))
    end
  end
end
