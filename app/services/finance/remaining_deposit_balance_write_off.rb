module Finance
  # Writes off the full outstanding amount of an open RemainingDepositBalance.
  # Appends a write_off ledger transaction and closes the balance.
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

    def err(key) = Result.new(ok: false, error: I18n.t("remaining_deposit_balances.errors.#{key}"))
  end
end
