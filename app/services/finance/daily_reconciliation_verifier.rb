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
      return err(:already_verified) if @reconciliation.verified?

      unless @reconciliation.closed? || @reconciliation.deposited?
        return err(:not_closed)
      end

      if @reconciliation.blocked_by_opening_float?
        return err(:verify_opening_float_pending)
      end

      if @reconciliation.till_handovers.pending.exists?
        return err(:verify_pending_handovers)
      end

      if @reconciliation.remaining_deposit_balances.open.exists?
        return err(:verify_outstanding_balances)
      end

      expected = @reconciliation.expected_cash_deposit
      if expected > 0 && @reconciliation.till_deposits.active.none?
        return err(:verify_no_deposit_recorded)
      end

      ActiveRecord::Base.transaction do
        @reconciliation.update!(
          state:       "verified",
          verified_by: @actor,
          verified_at: Time.current,
          notes:       @notes
        )

        log_audit(actor: @actor, auditable: @reconciliation, action: "verify",
                  metadata: { branch_id: @reconciliation.branch_id })

        Result.new(ok: true, reconciliation: @reconciliation)
      end
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: record_error_message(e.record))
    end

    private

    def record_error_message(failing_record)
      # If the DR itself fails with an association-level error (e.g. "Till deposits
      # is invalid"), propagate the child record's specific field errors instead.
      if failing_record.is_a?(DailyReconciliation) && failing_record.errors[:till_deposits].any?
        invalid_deposit = failing_record.till_deposits.find { |d| d.errors.any? }
        return invalid_deposit.errors.full_messages.to_sentence if invalid_deposit
      end
      failing_record.errors.full_messages.to_sentence
    end

    def err(key)
      Result.new(ok: false,
                 error: I18n.t("finance.daily_reconciliations.errors.#{key}"))
    end
  end
end
