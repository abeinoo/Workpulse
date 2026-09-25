module Finance
  # Accepts a pending DepositResponsibilityTransfer on behalf of the named recipient.
  #
  # On acceptance:
  #   - transfer is stamped with accepted_at / accepted_by
  #   - TillSession.depositor_id is updated to the accepting user
  #   - The accepting user may now record deposits for this DailyReconciliation
  #
  # Concurrency: the pending?/state re-checks and the mutation all happen
  # under the DR row lock (shared with the requester, rejecter, canceller,
  # DepositorAssigner and TillDepositRecorder), so of two racing accept/reject
  # clicks exactly one wins and the other gets a clear "no longer pending".
  class DepositResponsibilityTransferAcceptor
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

      # Super Admin (business owner) is never blocked by recipient assignment.
      unless @actor.owner? || @transfer.to_user_id == @actor.id
        return Result.new(ok: false, error: I18n.t("deposit_responsibility_transfers.errors.wrong_recipient"))
      end

      ActiveRecord::Base.transaction do
        dr = @transfer.daily_reconciliation
        dr.lock!
        @transfer.reload

        raise ArgumentError, I18n.t("deposit_responsibility_transfers.errors.already_accepted") if @transfer.accepted?
        raise ArgumentError, I18n.t("deposit_responsibility_transfers.errors.rejected")         if @transfer.rejected?
        raise ArgumentError, I18n.t("deposit_responsibility_transfers.errors.cancelled")        if @transfer.cancelled?
        raise ArgumentError, I18n.t("deposit_responsibility_transfers.errors.locked") unless dr.deposit_responsibility_transferable?

        @transfer.update!(accepted_at: Time.current, accepted_by: @actor)
        dr.till_session.update!(depositor: @actor)

        log_audit(actor: @actor, auditable: @transfer, action: "accept",
                  metadata: { daily_reconciliation_id: @transfer.daily_reconciliation_id,
                              previous_depositor_id:   @transfer.from_user_id })
      end

      Result.new(ok: true)
    rescue ArgumentError => e
      Result.new(ok: false, error: e.message)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
