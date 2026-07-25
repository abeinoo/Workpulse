module Finance
  # Records a cash deposit against a closed DailyReconciliation. A DR may
  # accumulate any number of deposits — each call creates a new, independent
  # TillDeposit row; nothing is ever merged or replaced. Total Deposited and
  # Remaining Deposit Due are always derived as SUM(active deposits) — see
  # DailyReconciliation#total_deposited / #pending_deposit_amount.
  #
  # If the deposited amount is less than the expected cash total for this
  # payment method, a RemainingDepositBalance is created in the same
  # transaction to track the shortfall.
  #
  # If a prior deposit already created an open RDB for the same PM, the new
  # deposit auto-settles or partially reduces that balance rather than creating
  # a second one.  All changes succeed or fail together — no partial state.
  #
  # Result#remaining_amount is non-nil when an outstanding shortfall still
  # exists for this PM after the deposit.
  #
  # Race-safe: the remaining-amount computation and the deposit creation both
  # happen inside a row lock on the DailyReconciliation, so two concurrent
  # submissions serialize — the second recomputes against the first's
  # committed total rather than a stale read. An optional idempotency_key
  # param (a client-generated token, one per form render) makes a retried
  # submission of the exact same request a no-op instead of a duplicate
  # financial record.
  class TillDepositRecorder
    include AuditLoggable

    Result = Struct.new(:ok, :deposit, :remaining_amount, :error, keyword_init: true) { def ok? = ok }

    def initialize(daily_reconciliation_id, actor:, params:)
      @daily_reconciliation_id = daily_reconciliation_id
      @actor                   = actor
      @params                  = params
    end

    def call
      @daily_reconciliation = DailyReconciliation
                                .where(business_id: @actor.business_id)
                                .includes(:till_session, :business, :branch)
                                .find(@daily_reconciliation_id)

      unless @daily_reconciliation.closed? || @daily_reconciliation.deposited?
        return Result.new(ok: false, error: I18n.t("till_deposits.errors.session_not_closed"))
      end

      session = @daily_reconciliation.till_session

      # Super Admin (business owner) is never blocked by depositor assignment.
      unless @actor.owner? || session&.depositor_id == @actor.id
        return Result.new(ok: false, error: I18n.t("till_deposits.errors.not_depositor"))
      end

      review_overridden = false
      unless @daily_reconciliation.reviewed?
        unless @actor.can?(:override_review_requirement)
          return Result.new(ok: false, error: I18n.t("till_deposits.errors.review_required"))
        end
        if @params[:override_review_reason].blank?
          return Result.new(ok: false, error: I18n.t("till_deposits.errors.override_reason_required"))
        end
        review_overridden = true
      end

      unless PaymentMethod.for_business(@daily_reconciliation.business).active.exists?(@params[:payment_method_id])
        return Result.new(ok: false, error: I18n.t("till_deposits.errors.invalid_payment_method"))
      end

      actual           = @params[:amount].to_d
      pm               = PaymentMethod.find(@params[:payment_method_id])
      idempotency_key  = @params[:idempotency_key].presence

      result = nil
      @daily_reconciliation.with_lock do
        if idempotency_key && (existing = @daily_reconciliation.till_deposits.find_by(idempotency_key: idempotency_key))
          result = Result.new(ok: true, deposit: existing, remaining_amount: nil)
          next
        end

        # Remaining balance only applies to cash-like methods. Recomputed here,
        # inside the lock, so a concurrent deposit already committed by another
        # request is reflected before this one is accepted or rejected.
        remaining_amount = nil
        if pm.cash_like?
          pm_session_total  = @daily_reconciliation.session_amounts
                                                    .where(payment_method_id: pm.id)
                                                    .sum("collected_amount - refund_amount")
          already_deposited = @daily_reconciliation.till_deposits.active
                                                    .where(payment_method_id: pm.id)
                                                    .sum(:amount)
          remaining_before  = pm_session_total - already_deposited

          if actual > remaining_before
            result = Result.new(ok: false,
                                error: I18n.t("till_deposits.errors.exceeds_remaining", remaining: remaining_before.to_s))
            next
          end

          shortfall        = remaining_before - actual
          remaining_amount = shortfall if shortfall > 0
        end

        deposit = @daily_reconciliation.till_deposits.create!(
          payment_method_id: pm.id,
          deposited_by:      @actor,
          amount:            actual,
          deposited_at:      @params[:deposited_at].presence || Time.current,
          reference:         @params[:reference],
          notes:             @params[:notes],
          idempotency_key:   idempotency_key
        )

        log_audit(actor: @actor, auditable: deposit, action: "create",
                  metadata: { amount: deposit.amount.to_s,
                               daily_reconciliation_id: @daily_reconciliation.id })

        if review_overridden
          log_audit(actor: @actor, auditable: deposit, action: "deposit_review_overridden",
                    metadata: { reason: @params[:override_review_reason] })
        end

        # Advance DR to "deposited" state on first deposit so downstream logic
        # (verifier guard, index stat card, view conditions) can distinguish
        # "closed but not yet deposited" from "deposited but not yet verified".
        # Note: "deposited" means "at least one deposit exists," not "fully
        # covered" — callers must check pending_deposit_amount separately.
        @daily_reconciliation.update!(state: "deposited") if @daily_reconciliation.closed?

        reconcile_remaining_balance!(pm, deposit, remaining_amount) if pm.cash_like?

        result = Result.new(ok: true, deposit: deposit, remaining_amount: remaining_amount)
      end
      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end

    private

    # Keeps the open RemainingDepositBalance for this PM in sync after each deposit.
    #
    # new_shortfall is the amount still owed for this PM after the current deposit
    # (nil means fully covered).
    #
    # Three cases:
    #   1. Existing open RDB + new shortfall reduced  → settle the difference
    #   2. Existing open RDB + no shortfall remaining → fully settle the RDB
    #   3. No existing RDB  + shortfall still exists  → create a new RDB
    def reconcile_remaining_balance!(pm, deposit, new_shortfall)
      open_rdb = @daily_reconciliation.remaining_deposit_balances
                   .open
                   .joins(:till_deposit)
                   .where(till_deposits: { payment_method_id: pm.id })
                   .first

      if open_rdb
        settlement_amount = open_rdb.remaining_amount - new_shortfall.to_d
        if settlement_amount > 0
          Finance::RemainingDepositBalanceSettler.new(
            open_rdb.id,
            actor:  @actor,
            amount: settlement_amount
          ).call
        end
      elsif new_shortfall
        balance = @daily_reconciliation.remaining_deposit_balances.create!(
          till_deposit:     deposit,
          responsible_user: @actor,
          created_by:       @actor,
          business:         @daily_reconciliation.business,
          branch:           @daily_reconciliation.branch,
          amount:           new_shortfall,
          remaining_amount: new_shortfall,
          status:           "open"
        )
        balance.balance_transactions.create!(
          transaction_type: "created",
          amount:           new_shortfall,
          performed_by:     @actor,
          notes:            @params[:notes]
        )
        log_audit(actor: @actor, auditable: balance, action: "create",
                  metadata: { amount:                  new_shortfall.to_s,
                               daily_reconciliation_id: @daily_reconciliation.id,
                               till_deposit_id:         deposit.id })
      end
    end
  end
end
