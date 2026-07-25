module Finance
  # Marks a DailyReconciliation's recorded deposit(s) as reviewed/approved by
  # a branch manager. Only available once at least one deposit exists —
  # this reviews the deposit itself (amount, date/time, reference, payment
  # method), not the closed session. Once reviewed, the deposit is locked
  # (see TillDepositPolicy#create?/#void?) unless the actor holds
  # override_review_requirement.
  class DailyReconciliationReviewer
    include AuditLoggable

    Result = Struct.new(:ok, :reconciliation, :error, keyword_init: true) { def ok? = ok }

    def initialize(reconciliation_id, actor:)
      @reconciliation_id = reconciliation_id
      @actor             = actor
    end

    def call
      @reconciliation = DailyReconciliation
                          .where(business_id: @actor.business_id)
                          .find(@reconciliation_id)

      return err(:already_reviewed) if @reconciliation.reviewed?
      return err(:review_not_deposited) unless @reconciliation.deposited?

      if @reconciliation.till_handovers.pending.exists?
        return err(:review_pending_handovers)
      end

      if @reconciliation.deposit_responsibility_transfers.pending.exists?
        return err(:review_pending_deposit_transfer)
      end

      ActiveRecord::Base.transaction do
        @reconciliation.update!(reviewed_by: @actor, reviewed_at: Time.current)

        log_audit(actor: @actor, auditable: @reconciliation, action: "review_completed")

        Result.new(ok: true, reconciliation: @reconciliation)
      end
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def err(key)
      Result.new(ok: false,
                 error: I18n.t("finance.daily_reconciliations.errors.#{key}"))
    end
  end
end
