module Finance
  # Directly assigns a depositor on a DailyReconciliation's TillSession,
  # bypassing the DepositResponsibilityTransfer workflow.  Only allowed when
  # no pending transfer exists for this DR.
  class DepositorAssigner
    include AuditLoggable

    Result = Struct.new(:ok, :error, keyword_init: true) { def ok? = ok }

    def initialize(daily_reconciliation_id, actor:, depositor_id:)
      @dr_id        = daily_reconciliation_id
      @actor        = actor
      @depositor_id = depositor_id.to_i
    end

    def call
      @dr = DailyReconciliation
              .where(business_id: @actor.business_id)
              .includes(:till_session)
              .find(@dr_id)

      if @dr.deposit_responsibility_transfers.pending.exists?
        return Result.new(ok: false,
                          error: I18n.t("finance.daily_reconciliations.errors.pending_transfer_exists"))
      end

      depositor = @actor.business.users.active.find_by(id: @depositor_id)
      unless depositor
        return Result.new(ok: false,
                          error: I18n.t("finance.daily_reconciliations.errors.invalid_depositor"))
      end

      ActiveRecord::Base.transaction do
        @dr.till_session.update!(depositor: depositor)

        log_audit(actor: @actor, auditable: @dr, action: "assign_depositor",
                  metadata: { depositor_id: depositor.id, depositor_name: depositor.full_name })
      end

      Result.new(ok: true)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
