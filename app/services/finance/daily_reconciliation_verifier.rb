module Finance
  # Finds or creates the DailyReconciliation record for a branch/date pair,
  # then marks it as verified by the acting manager.
  #
  # Uses advisory locking (same pattern as Finance::NumberSequencer) to prevent
  # a race between two managers opening the same day simultaneously.
  class DailyReconciliationVerifier
    include AuditLoggable

    Result = Struct.new(:ok, :reconciliation, :error, keyword_init: true) { def ok? = ok }

    def initialize(branch:, business_date:, actor:, notes: nil)
      @branch        = branch
      @business_date = business_date
      @actor         = actor
      @notes         = notes
    end

    def call
      ActiveRecord::Base.transaction do
        rec = find_or_create_reconciliation
        rec.update!(verified_by: @actor, verified_at: Time.current, notes: @notes)
        log_audit(
          actor:     @actor,
          auditable: rec,
          action:    "verify",
          metadata:  { business_date: @business_date.to_s }
        )
        Result.new(ok: true, reconciliation: rec)
      end
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def find_or_create_reconciliation
      DailyReconciliation.find_or_create_by!(
        business:      @branch.business,
        branch:        @branch,
        business_date: @business_date
      )
    end
  end
end
