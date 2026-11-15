module Finance
  # Shared engine of the Daily Reconciliation bulk shortage settlement. Settles
  # every open Remaining Deposit Balance (cash shortage) of the selected days in
  # FULL, through ONE destination chosen by a subclass — the two destinations
  # are mutually exclusive by construction (one operation, one destination, and
  # a settled balance is never open again):
  #
  #   * BulkShortageCustodySettler — credit a selected employee's custody account
  #     (Shortage Settlement Deposit); no payment method.
  #   * BulkShortageCashSettler    — receive the cash: the existing shortage
  #     "Receive" mechanism with the business's Cash payment method; no custody
  #     credit. (WorkPulse has no cash drawer ledger — nothing else is posted.)
  #
  # All-or-nothing, inside ONE transaction, under the canonical shortage lock
  # order shared with RemainingDepositBalanceSettler / RemainingDepositBalanceWriteOff
  # / TillDepositRecorder: DR rows by id → balance rows by id → destination row.
  # Eligibility is re-checked on the locked rows; any selected day without an
  # open shortage rejects the whole request. Totals come only from the database.
  #
  # Guards common to both destinations: settle_remaining_deposit_balance and
  # every DR inside the actor's DailyReconciliation scope (same business).
  #
  # Notes are OPTIONAL (owner decision 2026-11-15): blank / whitespace-only is
  # stored as NULL — never a placeholder. Traceability does not depend on them:
  # every settlement row names its balance (and custody credit or payment
  # method), and every audit entry carries the bulk reference, DR ids,
  # recipient / payment method and the original cashier.
  #
  # Subclass hooks: destination_permitted?, precheck_destination,
  # resolve_destination, lock_destination!, settle_one!, after_settlement!,
  # result_record.
  class BulkShortageSettlement
    include AuditLoggable

    Result = Struct.new(:ok, :record, :error, :total, :settled_count, :custody_transactions,
                        :ledger_transactions, keyword_init: true) { def ok? = ok }

    class Rejected < StandardError; end

    def initialize(daily_reconciliation_ids:, actor:, notes:)
      @dr_ids = Array(daily_reconciliation_ids).map(&:to_i).uniq.reject(&:zero?)
      @actor  = actor
      @notes  = notes.to_s.strip.presence # optional; nil when blank
    end

    def call
      return err(:none_selected)  if @dr_ids.empty?
      return err(:not_authorized) unless @actor.can?(:settle_remaining_deposit_balance) && destination_permitted?

      key = precheck_destination
      return err(key) if key

      reconciliations = load_reconciliations
      return err(:not_found) if reconciliations.size != @dr_ids.size

      key = resolve_destination
      return err(key) if key

      settle!(reconciliations)
    rescue Rejected => e
      err(e.message.to_sym)
    rescue ActiveRecord::RecordNotUnique
      # A database unique index caught a concurrent duplicate.
      err(:already_settled)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    rescue AuditLoggable::AuditWriteFailed
      err(:audit_failed)
    end

    private

    def load_reconciliations
      DailyReconciliationPolicy::Scope.new(@actor, DailyReconciliation).resolve
                                      .where(id: @dr_ids).includes(:branch).to_a
    end

    def settle!(reconciliations)
      bulk_reference = SecureRandom.uuid
      dr_by_id       = reconciliations.index_by(&:id)

      ActiveRecord::Base.transaction do
        DailyReconciliation.where(id: @dr_ids).order(:id).lock.pluck(:id)
        balances = RemainingDepositBalance.where(business_id: @actor.business_id,
                                                 daily_reconciliation_id: @dr_ids)
                                          .open.order(:id).lock
                                          .includes(:responsible_user).to_a
        lock_destination!

        balances = balances.select { |b| b.remaining_amount.positive? }
        settled_dr_ids = balances.map(&:daily_reconciliation_id).uniq
        raise Rejected, "already_settled" if (@dr_ids - settled_dr_ids).any?

        total = balances.sum(&:remaining_amount)
        raise Rejected, "amount_required" unless total.positive?

        posted = balances.map do |balance|
          settle_one!(balance, dr_by_id.fetch(balance.daily_reconciliation_id), bulk_reference)
        end

        after_settlement!(balances: balances, total: total, dr_ids: settled_dr_ids.sort,
                          posted: posted, bulk_reference: bulk_reference)

        build_result(total: total, settled_count: balances.size, posted: posted)
      end
    end

    # The balance's append-only "settlement" ledger row for its full remaining
    # amount, then the balance closes. responsible_user (the original cashier)
    # is never changed.
    def close_balance!(balance, **ledger_attrs)
      ledger_txn = balance.balance_transactions.create!(
        transaction_type: "settlement",
        amount:           balance.remaining_amount,
        performed_by:     @actor,
        notes:            @notes,
        **ledger_attrs
      )
      balance.update!(remaining_amount: 0, status: "settled", closed_at: Time.current)
      ledger_txn
    end

    def common_audit_metadata(balance, bulk_reference)
      { fully_settled: true, responsible_user_id: balance.responsible_user_id,
        bulk_reference: bulk_reference, daily_reconciliation_ids: @dr_ids.sort }
    end

    # Subclasses build results and refusals ONLY through these two helpers and
    # never name Result / Rejected themselves: inside a subclass a bare `Result`
    # resolves lexically to Finance::Result (Finance::DashboardFilters) before
    # this superclass's constant, whenever that file is loaded.
    def success(**attrs) = Result.new(ok: true, **attrs)
    def reject!(key) = raise(Rejected, key.to_s)

    # ── Hooks ──────────────────────────────────────────────────────────────────
    def destination_permitted? = raise(NotImplementedError)
    def precheck_destination = nil
    def resolve_destination = raise(NotImplementedError)
    def lock_destination! = nil
    def settle_one!(_balance, _dr, _bulk_reference) = raise(NotImplementedError)
    def after_settlement!(**) = nil
    def build_result(total:, settled_count:, posted:) = raise(NotImplementedError)

    def err(key)
      Result.new(ok: false, error: I18n.t("finance.daily_reconciliations.errors.bulk_settle.#{key}"))
    end
  end
end
