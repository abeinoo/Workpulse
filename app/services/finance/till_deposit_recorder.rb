module Finance
  # Records a cash deposit against a closed DailyReconciliation.
  #
  # If the deposited amount is less than the expected cash total for this
  # payment method, a RemainingDepositBalance is created in the same
  # transaction to track the shortfall.  Both records succeed or fail
  # together — there is no partial state.
  #
  # Result#remaining_amount is non-nil when a remaining balance was created.
  class TillDepositRecorder
    include AuditLoggable

    Result = Struct.new(:ok, :deposit, :remaining_amount, :error, keyword_init: true) { def ok? = ok }

    def initialize(daily_reconciliation, actor:, params:)
      @daily_reconciliation = daily_reconciliation
      @actor                = actor
      @params               = params
    end

    def call
      unless @daily_reconciliation.closed?
        return Result.new(ok: false, error: I18n.t("till_deposits.errors.session_not_closed"))
      end

      session = @daily_reconciliation.till_session

      unless session&.depositor_id == @actor.id
        return Result.new(ok: false, error: I18n.t("till_deposits.errors.not_depositor"))
      end

      unless PaymentMethod.for_business(@daily_reconciliation.business).active.exists?(@params[:payment_method_id])
        return Result.new(ok: false, error: I18n.t("till_deposits.errors.invalid_payment_method"))
      end

      actual = @params[:amount].to_d
      pm     = PaymentMethod.find(@params[:payment_method_id])

      # Remaining balance only applies to cash-like methods.
      remaining_amount = nil
      if pm.cash_like?
        pm_session_total  = @daily_reconciliation.session_amounts
                                                  .where(payment_method_id: pm.id)
                                                  .sum("collected_amount - refund_amount")
        already_deposited = @daily_reconciliation.till_deposits.active
                                                  .where(payment_method_id: pm.id)
                                                  .sum(:amount)
        shortfall        = (pm_session_total - already_deposited) - actual
        remaining_amount = shortfall if shortfall > 0
      end

      ActiveRecord::Base.transaction do
        deposit = @daily_reconciliation.till_deposits.create!(
          payment_method_id: pm.id,
          deposited_by:      @actor,
          amount:            actual,
          deposited_at:      @params[:deposited_at].presence || Time.current,
          reference:         @params[:reference],
          notes:             @params[:notes]
        )

        log_audit(actor: @actor, auditable: deposit, action: "create",
                  metadata: { amount: deposit.amount.to_s,
                               daily_reconciliation_id: @daily_reconciliation.id })

        if remaining_amount
          balance = @daily_reconciliation.remaining_deposit_balances.create!(
            till_deposit:     deposit,
            responsible_user: @actor,
            created_by:       @actor,
            business:         @daily_reconciliation.business,
            branch:           @daily_reconciliation.branch,
            amount:           remaining_amount,
            remaining_amount: remaining_amount,
            status:           "open"
          )

          # Seed the opening ledger transaction immediately so the audit trail
          # starts from the moment of creation, not from the first settlement.
          balance.balance_transactions.create!(
            transaction_type: "created",
            amount:           remaining_amount,
            performed_by:     @actor,
            notes:            @params[:notes]
          )

          log_audit(actor: @actor, auditable: balance, action: "create",
                    metadata: { amount:                  remaining_amount.to_s,
                                 daily_reconciliation_id: @daily_reconciliation.id,
                                 till_deposit_id:         deposit.id })
        end

        Result.new(ok: true, deposit: deposit, remaining_amount: remaining_amount)
      end
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
