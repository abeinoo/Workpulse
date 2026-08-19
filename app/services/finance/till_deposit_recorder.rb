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
        # request — or an open ATM Deposit Dispute that already accounts for
        # part of this amount — is reflected before this one is accepted or
        # rejected. Shared with the Record Deposit dialog's displayed figures
        # via DailyReconciliation#remaining_by_payment_method so the two can
        # never disagree.
        remaining_amount = nil
        if pm.cash_like?
          remaining_before = @daily_reconciliation.remaining_by_payment_method[pm.id] || 0

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
    # Four cases:
    #   1. Existing open RDB + new shortfall reduced  → settle the difference
    #   2. Existing open RDB + no shortfall remaining → fully settle the RDB
    #   3. Existing open RDB + new shortfall LARGER    → append an adjustment
    #      raising it to match. This is not a hypothetical: an RDB can be
    #      left open with a stale (too-small) remaining_amount when the
    #      deposit that originally created it is later voided/corrected —
    #      voiding a deposit never touches its RDB — and the replacement
    #      deposit then reveals a bigger true shortfall (e.g. because an
    #      open ATM Deposit Dispute now also reduces what's available). The
    #      ledger must never silently understate the true shortfall.
    #   4. No existing RDB  + shortfall still exists  → create a new RDB
    def reconcile_remaining_balance!(pm, deposit, new_shortfall)
      open_rdb = @daily_reconciliation.remaining_deposit_balances
                   .open
                   .joins(:till_deposit)
                   .where(till_deposits: { payment_method_id: pm.id })
                   .first

      if open_rdb
        delta = new_shortfall.to_d - open_rdb.remaining_amount
        if delta.negative?
          Finance::RemainingDepositBalanceSettler.new(
            open_rdb.id,
            actor:  @actor,
            amount: -delta
          ).call
        elsif delta.positive?
          increase_remaining_balance!(open_rdb, delta)
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

    # Appends an append-only adjustment raising an existing open balance's
    # remaining_amount — never mutates the earlier "created"/settlement
    # transactions, this is a new, separate ledger entry. Also raises the
    # balance's own `amount` (the all-time total ever owed) by the same
    # delta, so `amount - remaining_amount` ("settled since") keeps meaning
    # "cumulative real settlements" rather than going negative.
    def increase_remaining_balance!(balance, delta)
      balance.balance_transactions.create!(
        transaction_type: "adjustment",
        amount:           delta,
        performed_by:     @actor,
        notes:            "Shortfall increased to #{balance.remaining_amount + delta} after this deposit"
      )

      balance.update!(
        amount:            balance.amount + delta,
        remaining_amount:  balance.remaining_amount + delta
      )

      log_audit(actor: @actor, auditable: balance, action: "adjustment",
                metadata: { amount:                  delta.to_s,
                             daily_reconciliation_id: @daily_reconciliation.id,
                             reason:                  "shortfall_increased_by_new_deposit" })
    end
  end
end
