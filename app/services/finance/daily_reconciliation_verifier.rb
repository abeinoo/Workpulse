module Finance
  # Marks a DailyReconciliation as verified by a manager.
  class DailyReconciliationVerifier
    include AuditLoggable

    Result = Struct.new(:ok, :reconciliation, :error, keyword_init: true) { def ok? = ok }

    def initialize(reconciliation, actor:, notes: nil)
      @reconciliation = reconciliation
      @actor          = actor
      @notes          = notes
    end

    def call
      ActiveRecord::Base.transaction do
        @reconciliation.update!(
          verified_by: @actor,
          verified_at: Time.current,
          notes:       @notes
        )

        log_audit(actor: @actor, auditable: @reconciliation, action: "verify",
                  metadata: { branch_id: @reconciliation.branch_id })

        Result.new(ok: true, reconciliation: @reconciliation)
      end
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
