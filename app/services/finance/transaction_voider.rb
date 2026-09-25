module Finance
  # Reverses a custody transaction by VOIDING it (never deleting), preserving the
  # ledger. A voided transaction drops out of the balance (Voidable's `active`
  # scope). A transaction locked into a settlement can't be voided until the
  # settlement is rejected. Voiding one leg of a transfer voids its counterpart
  # too, so paired balances stay consistent.
  #
  # A movement linked to a FinancialSettlement (CustodyTransaction#settlement_linked?,
  # e.g. a goods receipt payment from custody) is refused: it must be undone by
  # reversing the settlement (Inventory::GoodsReceiptSettlementReverser), which
  # keeps custody and the document's paid amount in step. The model enforces
  # the same rule as a backstop.
  class TransactionVoider
    include AuditLoggable

    Result = Struct.new(:ok, :transaction, :error, keyword_init: true) { def ok? = ok }

    def initialize(transaction, user:, reason:)
      @txn    = transaction
      @user   = user
      @reason = reason
    end

    def call
      return err(I18n.t("finance.custody.errors.already_voided")) if @txn.voided?
      return err(I18n.t("finance.custody.errors.settlement_linked")) if @txn.settlement_linked?
      return err(I18n.t("finance.custody.errors.reason_required")) if @reason.blank?

      counterpart = @txn.transfer_counterparty
      ActiveRecord::Base.transaction do
        mark_voided(@txn)
        mark_voided(counterpart) if counterpart && !counterpart.voided?

        @txn.custody_account.refresh_balance!
        counterpart&.custody_account&.refresh_balance!

        log_audit(actor: @user, auditable: @txn, action: "custody_void",
                  metadata: { reason: @reason })
      end
      Result.new(ok: true, transaction: @txn)
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.to_sentence)
    end

    private

    def mark_voided(txn)
      txn.update!(voided_at: Time.current, voided_by: @user, void_reason: @reason)
    end

    def err(message)
      Result.new(ok: false, transaction: @txn, error: message)
    end
  end
end
