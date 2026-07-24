module Finance
  # Voids a TillDeposit and brings every derived deposit calculation back in
  # sync with reality.
  #
  # DailyReconciliation#total_deposited / #pending_deposit_amount and the
  # deposit form's expected_amounts_by_pm already recompute live from
  # till_deposits.active, so voiding a deposit alone is enough to fix those —
  # nothing else to do there.
  #
  # The one piece of state that does NOT self-correct is the
  # RemainingDepositBalance ledger: if the voided deposit had settled (fully
  # or partially) an open balance for its payment method, that balance stays
  # stale — still showing the smaller, pre-void shortfall — unless we reopen
  # or top it back up here. This is the only entry point that does so; never
  # void a TillDeposit with a bare #update from a controller.
  #
  # Also reverts the DR from "deposited" back to "closed" when this was the
  # last active deposit — state is derived from data shape, and a DR with zero
  # active deposits was never actually deposited.
  class TillDepositVoider
    include AuditLoggable

    Result = Struct.new(:ok, :deposit, :error, keyword_init: true) { def ok? = ok }

    def initialize(till_deposit_id, actor:, void_reason:)
      @till_deposit_id = till_deposit_id
      @actor           = actor
      @void_reason     = void_reason
    end

    def call
      deposit = TillDeposit
                  .joins(:daily_reconciliation)
                  .where(daily_reconciliations: { business_id: @actor.business_id })
                  .find(@till_deposit_id)

      result = nil
      deposit.daily_reconciliation.with_lock do
        if deposit.voided?
          result = Result.new(ok: false, error: I18n.t("till_deposits.errors.already_voided"))
          next
        end

        deposit.update!(voided_at: Time.current, voided_by: @actor, void_reason: @void_reason)

        log_audit(actor: @actor, auditable: deposit, action: "void",
                  metadata: { void_reason: @void_reason, amount: deposit.amount.to_s,
                               daily_reconciliation_id: deposit.daily_reconciliation_id })

        reconcile_remaining_balance!(deposit)
        revert_deposited_state!(deposit.daily_reconciliation)

        result = Result.new(ok: true, deposit: deposit)
      end
      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end

    private

    # Recomputes the true outstanding shortfall for this deposit's payment
    # method now that the voided deposit no longer counts, and brings the
    # open RemainingDepositBalance (if any) back in line — appending a ledger
    # transaction rather than mutating history, per the append-only ledger rule.
    def reconcile_remaining_balance!(deposit)
      pm = deposit.payment_method
      return unless pm.cash_like?

      dr = deposit.daily_reconciliation
      pm_session_total  = dr.session_amounts.where(payment_method_id: pm.id)
                             .sum("collected_amount - refund_amount")
      already_deposited = dr.till_deposits.active.where(payment_method_id: pm.id).sum(:amount)
      true_shortfall    = pm_session_total - already_deposited

      # An open RDB for this PM is only discoverable via its causing deposit's
      # payment_method_id (there's no payment_method_id column on the balance
      # itself) — matches the lookup already used in TillDepositRecorder.
      open_rdb = dr.remaining_deposit_balances.open
                   .joins(:till_deposit)
                   .where(till_deposits: { payment_method_id: pm.id })
                   .first

      if open_rdb
        delta = true_shortfall - open_rdb.remaining_amount
        return if delta.zero?

        if delta.positive?
          open_rdb.balance_transactions.create!(
            transaction_type: "adjustment",
            amount:           delta,
            performed_by:     @actor,
            notes:            "Reopened after voiding deposit ##{deposit.id}"
          )
          open_rdb.update!(remaining_amount: true_shortfall)
          log_audit(actor: @actor, auditable: open_rdb, action: "reopen_after_void",
                    metadata: { delta: delta.to_s, new_remaining: true_shortfall.to_s,
                                 voided_till_deposit_id: deposit.id })
        else
          Finance::RemainingDepositBalanceSettler.new(
            open_rdb.id, actor: @actor, amount: -delta,
            notes: "Adjusted after voiding deposit ##{deposit.id}"
          ).call
        end
      elsif true_shortfall.positive?
        # No open balance exists at all (the voided deposit had fully covered
        # this PM) — the void reintroduces a shortfall, so open a new one.
        # till_deposit stays pointed at the (now voided) deposit purely so the
        # payment-method lookup above can still find this balance later — it
        # is not claiming the voided deposit caused the shortfall.
        balance = dr.remaining_deposit_balances.create!(
          till_deposit:     deposit,
          responsible_user: deposit.deposited_by,
          created_by:       @actor,
          business:         dr.business,
          branch:           dr.branch,
          amount:           true_shortfall,
          remaining_amount: true_shortfall,
          status:           "open"
        )
        balance.balance_transactions.create!(
          transaction_type: "created",
          amount:           true_shortfall,
          performed_by:     @actor,
          notes:            "Opened after voiding deposit ##{deposit.id}"
        )
        log_audit(actor: @actor, auditable: balance, action: "create",
                  metadata: { amount: true_shortfall.to_s, daily_reconciliation_id: dr.id,
                               reason: "deposit_voided", voided_till_deposit_id: deposit.id })
      end
    end

    def revert_deposited_state!(dr)
      return unless dr.deposited?
      return if dr.till_deposits.active.exists?

      dr.update!(state: "closed")
      log_audit(actor: @actor, auditable: dr, action: "deposited_state_reverted",
                metadata: { reason: "Last active deposit was voided." })
    end
  end
end
