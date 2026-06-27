module Finance
  # Cancels a pending DepositResponsibilityTransfer.
  #
  # The original cashier (from_user) or a manager may cancel while the transfer
  # is pending. Once cancelled:
  #   - The from_user retains depositor_id on TillSession (no change needed)
  #   - The unique partial index allows a new transfer to be created
  #   - The audit history is preserved; cancelled_at is additive
  class DepositResponsibilityTransferCanceller
    include AuditLoggable

    Result = Struct.new(:ok, :error, keyword_init: true) { def ok? = ok }

    def initialize(transfer, actor:)
      @transfer = transfer
      @actor    = actor
    end

    def call
      return Result.new(ok: false, error: I18n.t("deposit_responsibility_transfers.errors.not_pending")) unless @transfer.pending?

      ActiveRecord::Base.transaction do
        @transfer.update!(cancelled_at: Time.current, cancelled_by: @actor)

        log_audit(actor: @actor, auditable: @transfer, action: "cancel",
                  metadata: { daily_reconciliation_id: @transfer.daily_reconciliation_id,
                               cancelled_to_user_id:   @transfer.to_user_id })
      end

      Result.new(ok: true)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
