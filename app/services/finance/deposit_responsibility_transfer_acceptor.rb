module Finance
  # Accepts a pending DepositResponsibilityTransfer on behalf of the named recipient.
  #
  # On acceptance:
  #   - transfer is stamped with accepted_at
  #   - TillSession.depositor_id is updated to the accepting user
  #   - The accepting user may now record deposits for this DailyReconciliation
  class DepositResponsibilityTransferAcceptor
    include AuditLoggable

    Result = Struct.new(:ok, :error, keyword_init: true) { def ok? = ok }

    def initialize(transfer, actor:)
      @transfer = transfer
      @actor    = actor
    end

    def call
      return Result.new(ok: false, error: I18n.t("deposit_responsibility_transfers.errors.already_accepted")) if @transfer.accepted?
      return Result.new(ok: false, error: I18n.t("deposit_responsibility_transfers.errors.cancelled"))        if @transfer.cancelled?
      return Result.new(ok: false, error: I18n.t("deposit_responsibility_transfers.errors.wrong_recipient"))  unless @transfer.to_user == @actor

      ActiveRecord::Base.transaction do
        @transfer.update!(accepted_at: Time.current)
        @transfer.daily_reconciliation.till_session.update!(depositor: @actor)

        log_audit(actor: @actor, auditable: @transfer, action: "accept",
                  metadata: { daily_reconciliation_id: @transfer.daily_reconciliation_id })
      end

      Result.new(ok: true)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
