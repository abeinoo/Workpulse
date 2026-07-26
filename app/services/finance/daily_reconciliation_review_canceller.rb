module Finance
  # Undoes a completed Branch Review of the recorded deposit. Only allowed
  # before the accountant has finished bank verification — once verified,
  # the review is locked and read-only.
  #
  # This is a FULL ROLLBACK of the deposit approval, not just clearing the
  # review flag: "cancelled approval" means the recorded deposit was not
  # accepted, so every active TillDeposit on this DR is voided (through
  # TillDepositVoider — the only entry point allowed to set voided_at, per
  # its own doc comment) and the employee must record a brand new deposit
  # from scratch. Voiding the deposits naturally reverts the DR from
  # "deposited" back to "closed" (TillDepositVoider#revert_deposited_state!),
  # which is exactly the "Ready for Deposit" state — Record Deposit and
  # Report ATM Deposit Issue become available again purely because the
  # state-derived policies (TillDepositPolicy#create?, BankDisputePolicy)
  # already key off closed?/reviewed?, no separate re-enable step needed.
  class DailyReconciliationReviewCanceller
    include AuditLoggable

    Result = Struct.new(:ok, :reconciliation, :error, keyword_init: true) { def ok? = ok }

    DepositVoidFailedError = Class.new(StandardError)

    def initialize(reconciliation_id, actor:)
      @reconciliation_id = reconciliation_id
      @actor             = actor
    end

    def call
      @reconciliation = DailyReconciliation
                          .where(business_id: @actor.business_id)
                          .find(@reconciliation_id)

      return err(:review_not_reviewed) unless @reconciliation.reviewed?
      return err(:review_locked_after_verification) if @reconciliation.verified?
      return err(:review_not_deposited) unless @reconciliation.deposited?

      @reconciliation.with_lock do
        @reconciliation.update!(reviewed_by_id: nil, reviewed_at: nil)

        voided_ids = void_active_deposits!

        # Safety net: TillDepositVoider already reverts deposited? -> closed
        # when it voids the last active deposit, but if every deposit was
        # somehow already voided out-of-band before this ran (so the loop
        # above did nothing), force the same "Ready for Deposit" outcome —
        # a rolled-back review must never leave the DR stuck in "deposited"
        # with no active deposit backing it.
        @reconciliation.update!(state: "closed") if @reconciliation.reload.deposited?

        log_audit(actor: @actor, auditable: @reconciliation, action: "review_cancelled",
                  metadata: { voided_till_deposit_ids: voided_ids })
      end

      # Every void above ran through TillDepositVoider on its own freshly
      # loaded TillDeposit/DailyReconciliation instances (never this one), so
      # @reconciliation's in-memory attributes and association cache
      # (till_deposits, etc.) could otherwise disagree with what was actually
      # committed. #reload wipes both, so any caller — controller redirect,
      # console usage, a future turbo_stream response — reads the true
      # post-rollback state (state: "closed", reviewed_at/by: nil, zero
      # active deposits) straight from the database, never a stale copy.
      Result.new(ok: true, reconciliation: @reconciliation.reload)
    rescue DepositVoidFailedError => e
      Result.new(ok: false, error: e.message)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end

    private

    # Rolls back every active deposit on this DR — the recorded deposit was
    # not accepted, so none of it carries forward. Returns the voided ids for
    # the audit metadata above.
    def void_active_deposits!
      reason = I18n.t("finance.daily_reconciliations.errors.deposit_voided_on_review_cancel")

      @reconciliation.till_deposits.active.order(:id).map do |deposit|
        result = Finance::TillDepositVoider.new(deposit.id, actor: @actor, void_reason: reason).call
        raise DepositVoidFailedError, result.error unless result.ok?

        deposit.id
      end
    end

    def err(key)
      Result.new(ok: false,
                 error: I18n.t("finance.daily_reconciliations.errors.#{key}"))
    end
  end
end
