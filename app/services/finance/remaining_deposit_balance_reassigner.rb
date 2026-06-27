module Finance
  # Transfers responsibility for an open RemainingDepositBalance to a new user
  # without changing the outstanding amount.  Appends a ledger transaction so
  # the full chain of custody is preserved.
  class RemainingDepositBalanceReassigner
    Result = Struct.new(:ok, :balance, :transaction, :error, keyword_init: true) { def ok? = ok }

    def initialize(balance, actor:, new_user:, notes: nil)
      @balance  = balance
      @actor    = actor
      @new_user = new_user
      @notes    = notes
    end

    def call
      return err("not_open")   unless @balance.open?
      return err("same_user")  if @new_user.id == @balance.responsible_user_id

      ActiveRecord::Base.transaction do
        prev_user = @balance.responsible_user

        txn = @balance.balance_transactions.create!(
          transaction_type:          "reassignment",
          performed_by:              @actor,
          previous_responsible_user: prev_user,
          new_responsible_user:      @new_user,
          notes:                     @notes
        )

        @balance.update!(responsible_user: @new_user)

        Result.new(ok: true, balance: @balance, transaction: txn)
      end
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def err(key) = Result.new(ok: false, error: I18n.t("remaining_deposit_balances.errors.#{key}"))
  end
end
