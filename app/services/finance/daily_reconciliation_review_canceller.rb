module Finance
  # Undoes a completed Branch Review. Only allowed before the first deposit
  # exists — once a deposit is recorded, review becomes locked and read-only.
  class DailyReconciliationReviewCanceller
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

      return err(:review_not_reviewed) unless @reconciliation.reviewed?
      return err(:review_not_closed)   unless @reconciliation.closed?
      return err(:review_locked_after_deposit) if @reconciliation.total_deposited.positive?

      ActiveRecord::Base.transaction do
        @reconciliation.update!(reviewed_by_id: nil, reviewed_at: nil)

        log_audit(actor: @actor, auditable: @reconciliation, action: "review_cancelled")

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
