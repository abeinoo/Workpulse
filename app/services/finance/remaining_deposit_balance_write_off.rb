module Finance
  # Writes off the full outstanding amount of an open RemainingDepositBalance.
  # Appends a write_off ledger transaction and closes the balance.
  #
  # Concurrency: same canonical lock order as RemainingDepositBalanceSettler
  # and BulkShortageCustodySettler (DailyReconciliation row, then balance row)
  # and the open check is repeated on the locked, freshly read row, so a write-
  # off can never follow a concurrent settlement (or another write-off) of the
  # same balance; the amount written off is the remaining amount under the lock.
  class RemainingDepositBalanceWriteOff
    include AuditLoggable

    Result = Struct.new(:ok, :balance, :transaction, :error, keyword_init: true) { def ok? = ok }

    def initialize(balance_id, actor:, notes: nil)
      @balance_id = balance_id
      @actor      = actor
      @notes      = notes
    end

    def call
      @balance = RemainingDepositBalance.where(business_id: @actor.business_id).find(@balance_id)

      return err("not_open") unless @balance.open?

      ActiveRecord::Base.transaction do
        lock_balance!
        next err("not_open") unless @balance.open?

        txn = @balance.balance_transactions.create!(
          transaction_type: "write_off",
          amount:           @balance.remaining_amount,
          performed_by:     @actor,
          notes:            @notes
        )

        @balance.update!(
          remaining_amount: 0,
          status:           "written_off",
          closed_at:        Time.current
        )

        log_audit(actor: @actor, auditable: @balance, action: "write_off",
                  metadata: { amount: @balance.amount.to_s })

        Result.new(ok: true, balance: @balance, transaction: txn)
      end
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end

    private

    # DR row, then balance row (reloaded) — see the class comment.
    def lock_balance!
      DailyReconciliation.where(id: @balance.daily_reconciliation_id).lock.pluck(:id)
      @balance.lock!
    end

    def err(key) = Result.new(ok: false, error: I18n.t("remaining_deposit_balances.errors.#{key}"))
  end
end
