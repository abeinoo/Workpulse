module Finance
  # Marks a DailyReconciliation as verified by a manager.
  class DailyReconciliationVerifier
    include AuditLoggable

    Result = Struct.new(:ok, :reconciliation, :error, keyword_init: true) { def ok? = ok }

    def initialize(reconciliation_id, actor:, notes: nil)
      @reconciliation_id = reconciliation_id
      @actor             = actor
      @notes             = notes
    end

    def call
      @reconciliation = DailyReconciliation
                          .where(business_id: @actor.business_id)
                          .find(@reconciliation_id)

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

      # Direct check against the same number the rest of the app already
      # trusts (pending_deposit_amount) — a partial deposit advances DR.state
      # to "deposited" (see Finance::TillDepositRecorder), so state alone
      # can't be used to infer full coverage. The open-RDB guard above is an
      # indirect signal that depends on the ledger being in sync; this is the
      # direct one.
      if @reconciliation.pending_deposit_amount > 0
        return err(:verify_deposit_incomplete)
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
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def err(key)
      Result.new(ok: false,
                 error: I18n.t("finance.daily_reconciliations.errors.#{key}"))
    end
  end
end
