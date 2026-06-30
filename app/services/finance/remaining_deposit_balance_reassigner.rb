module Finance
  # Transfers responsibility for an open RemainingDepositBalance to a new user
  # without changing the outstanding amount.  Appends a ledger transaction so
  # the full chain of custody is preserved.
  class RemainingDepositBalanceReassigner
    include AuditLoggable

    Result = Struct.new(:ok, :balance, :transaction, :error, keyword_init: true) { def ok? = ok }

    def initialize(balance_id, actor:, new_user_id:, notes: nil)
      @balance_id  = balance_id
      @actor       = actor
      @new_user_id = new_user_id.to_i
      @notes       = notes
    end

    def call
      @balance  = RemainingDepositBalance.where(business_id: @actor.business_id).find(@balance_id)
      @new_user = User.where(business_id: @actor.business_id, active: true).find_by(id: @new_user_id)
      return err("invalid_user") if @new_user.nil?

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

        log_audit(actor: @actor, auditable: @balance, action: "reassign",
                  metadata: { from_user_id: prev_user.id, to_user_id: @new_user.id })

        Result.new(ok: true, balance: @balance, transaction: txn)
      end
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def err(key) = Result.new(ok: false, error: I18n.t("remaining_deposit_balances.errors.#{key}"))
  end
end
