module Finance
  # Partially or fully settles an open RemainingDepositBalance by appending
  # a ledger transaction.  The balance closes automatically when remaining_amount
  # reaches zero.
  class RemainingDepositBalanceSettler
    Result = Struct.new(:ok, :balance, :transaction, :error, keyword_init: true) { def ok? = ok }

    def initialize(balance, actor:, amount:, notes: nil, payment_method_id: nil, reference_number: nil)
      @balance           = balance
      @actor             = actor
      @amount            = amount.to_d
      @notes             = notes
      @payment_method_id = payment_method_id.presence
      @reference_number  = reference_number.presence
    end

    def call
      return err("not_open")       unless @balance.open?
      return err("amount_required") unless @amount > 0
      return err("exceeds_balance") if @amount > @balance.remaining_amount

      ActiveRecord::Base.transaction do
        new_remaining = @balance.remaining_amount - @amount
        fully_settled = new_remaining.zero?

        txn = @balance.balance_transactions.create!(
          transaction_type:  "settlement",
          amount:            @amount,
          performed_by:      @actor,
          notes:             @notes,
          payment_method_id: @payment_method_id,
          reference_number:  @reference_number
        )

        @balance.update!(
          remaining_amount: new_remaining,
          status:           fully_settled ? "settled" : "open",
          closed_at:        fully_settled ? Time.current : nil
        )

        Result.new(ok: true, balance: @balance, transaction: txn)
      end
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def err(key) = Result.new(ok: false, error: I18n.t("remaining_deposit_balances.errors.#{key}"))
  end
end
