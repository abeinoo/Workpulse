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

      # A remaining deposit balance (partial deposit, cash leftovers, machine
      # limits) is normal and does not block verification — it's tracked and
      # settled independently via the RemainingDepositBalance ledger. An open
      # ATM Deposit Dispute counts the same way: the employee has already
      # declared what happened to that cash, so it's being tracked by the
      # Bank Dispute workflow instead. Only the absence of BOTH any deposit
      # and any open dispute blocks verification — nothing has happened yet.
      expected = @reconciliation.expected_cash_deposit
      if expected > 0 && @reconciliation.till_deposits.active.none? &&
         @reconciliation.open_atm_dispute_amount.zero?
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
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def err(key)
      Result.new(ok: false,
                 error: I18n.t("finance.daily_reconciliations.errors.#{key}"))
    end
  end
end
