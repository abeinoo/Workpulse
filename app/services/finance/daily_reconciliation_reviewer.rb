module Finance
  # Marks a closed DailyReconciliation as reviewed by a branch manager — the
  # mandatory checkpoint before a deposit may be recorded (unless the actor
  # holds override_review_requirement).
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
      return err(:review_not_closed) unless @reconciliation.closed?

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
