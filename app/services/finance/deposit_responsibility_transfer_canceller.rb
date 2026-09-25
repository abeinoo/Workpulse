module Finance
  # Cancels a pending DepositResponsibilityTransfer.
  #
  # The original cashier (from_user) or a manager may cancel while the transfer
  # is pending. Once cancelled:
  #   - The from_user retains depositor_id on TillSession (no change needed)
  #   - The unique partial index allows a new transfer to be created
  #   - The audit history is preserved; cancelled_at is additive
  #
  # The pending? re-check runs under the DR row lock shared with the
  # acceptor/rejecter, so a cancel can't land on a transfer that was accepted
  # a moment earlier.
  class DepositResponsibilityTransferCanceller
    include AuditLoggable

    Result = Struct.new(:ok, :error, keyword_init: true) { def ok? = ok }

    def initialize(transfer_id, actor:)
      @transfer_id = transfer_id
      @actor       = actor
    end

    def call
      @transfer = DepositResponsibilityTransfer
                    .joins(:daily_reconciliation)
                    .where(daily_reconciliations: { business_id: @actor.business_id })
                    .find(@transfer_id)

      ActiveRecord::Base.transaction do
        @transfer.daily_reconciliation.lock!
        @transfer.reload
        raise ArgumentError, I18n.t("deposit_responsibility_transfers.errors.not_pending") unless @transfer.pending?

        @transfer.update!(cancelled_at: Time.current, cancelled_by: @actor)

        log_audit(actor: @actor, auditable: @transfer, action: "cancel",
                  metadata: { daily_reconciliation_id: @transfer.daily_reconciliation_id,
                               cancelled_to_user_id:   @transfer.to_user_id })
      end

      Result.new(ok: true)
    rescue ArgumentError => e
      Result.new(ok: false, error: e.message)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
