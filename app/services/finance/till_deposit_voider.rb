module Finance
  # Voids a TillDeposit. This is the only entry point that may set
  # voided_at/voided_by/void_reason on a TillDeposit — never do it with a bare
  # #update from a controller.
  #
  # By design this does nothing beyond voiding + auditing + the DR state
  # check below. It deliberately does NOT try to restore or reassign the
  # original depositor's "responsibility" for the voided amount via
  # RemainingDepositBalance — an accountant/manager voids the wrong deposit
  # and simply records a correct replacement afterward. That replacement goes
  # through the ordinary Finance::TillDepositRecorder path, which already
  # computes its own shortfall/RemainingDepositBalance from
  # till_deposits.active — the same as any other deposit, with no special
  # casing for "this follows a void."
  #
  # DailyReconciliation#total_deposited / #pending_deposit_amount and the
  # deposit form's expected_amounts_by_pm all recompute live from
  # till_deposits.active, so voiding a deposit alone is enough to keep every
  # summary/total correct — nothing else to reconcile.
  #
  # Also reverts the DR from "deposited" back to "closed" when this was the
  # last active deposit — state is derived from data shape, and a DR with zero
  # active deposits was never actually deposited. This never blocks a
  # replacement deposit either way: TillDepositRecorder accepts both "closed"
  # and "deposited" DRs.
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

        revert_deposited_state!(deposit.daily_reconciliation)

        result = Result.new(ok: true, deposit: deposit)
      end
      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def revert_deposited_state!(dr)
      return unless dr.deposited?
      return if dr.till_deposits.active.exists?

      dr.update!(state: "closed")
      log_audit(actor: @actor, auditable: dr, action: "deposited_state_reverted",
                metadata: { reason: "Last active deposit was voided." })
    end
  end
end
