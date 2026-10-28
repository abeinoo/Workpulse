module Finance
  module BankStatements
    # Manually links one or more BankStatementTransactions to a TillDeposit.
    #
    # A deposit may be matched by several transactions (e.g. one physical
    # $11,700 deposit appearing on the bank side as separate $7,000 + $4,700
    # lines) — each pairing is its own DepositMatch row. The running total
    # (DepositMatch#matched_amount summed) is never allowed to exceed the
    # deposit's own amount: linking a transaction that would push the total
    # over is rejected for the whole batch, nothing is linked.
    #
    # Landing at or under the deposit amount is a valid, persistent state
    # (:partially_matched / :fully_matched — see TillDeposit#match_status) —
    # transactions can be added incrementally across separate calls as more
    # bank statements are imported over time.
    #
    # The deposit is locked with FOR UPDATE inside the transaction to prevent
    # two concurrent requests from over-matching the same deposit (TOCTOU).
    class ManualMatcher
      include AuditLoggable

      Result = Struct.new(:ok, :transaction, :transactions, :error, keyword_init: true) do
        def ok? = ok
      end

      # Single-transaction entry point — matches this one transaction to the
      # given deposit. Used from the transaction's own "pick a deposit" flow.
      def self.call(transaction_id, till_deposit_id:, actor:, notes: nil)
        new(till_deposit_id: till_deposit_id, transaction_ids: [ transaction_id ],
            actor: actor, notes: notes).call
      end

      # Multi-transaction entry point — matches every given transaction to
      # the one deposit in a single atomic batch. Used from the deposit's own
      # "select multiple transactions" flow.
      def self.call_many(till_deposit_id:, transaction_ids:, actor:, notes: nil)
        new(till_deposit_id: till_deposit_id, transaction_ids: transaction_ids,
            actor: actor, notes: notes).call
      end

      def initialize(till_deposit_id:, transaction_ids:, actor:, notes: nil)
        @till_deposit_id = till_deposit_id
        @transaction_ids = Array(transaction_ids).map(&:to_i)
        @actor           = actor
        @notes           = notes
      end

      def call
        return err("reason_required") if @notes.blank?

        txns = BankStatementTransaction
                 .where(business: @actor.business)
                 .where(id: @transaction_ids)
                 .to_a
        return err("not_found") unless txns.size == @transaction_ids.size

        linked = []

        ActiveRecord::Base.transaction do
          # Lock order, shared by every bank-match path: the transactions (by
          # id) first, then the deposit — MatchingEngine and TillDepositVoider
          # take them in the same order, so they serialize instead of
          # deadlocking. Their statement is read after the lock: a statement
          # deleted meanwhile has already released its matches and must not
          # gain a new one.
          txns = BankStatementTransaction.where(id: txns.map(&:id)).order(:id)
                                         .lock.includes(:bank_statement).to_a

          # Lock the deposit row before checking availability to eliminate the
          # TOCTOU window between "how much is left?" and "claim it". Only the
          # deposit: a plain FOR UPDATE would also lock the joined DR, deposit
          # first — the reverse of TillDepositVoider (DR, then deposit), a
          # deadlock. The deposit lock alone serializes with a void, which
          # locks the deposit before voiding it.
          deposit = TillDeposit
                      .joins(:daily_reconciliation)
                      .where(daily_reconciliations: { business_id: @actor.business.id })
                      .where(voided_at: nil)
                      .lock("FOR UPDATE OF till_deposits")
                      .find(@till_deposit_id)

          raise StatementDeletedError if txns.any? { |t| t.bank_statement.deleted? }

          already_matched = txns.select(&:matched?)
          if already_matched.any? { |t| t.matched_till_deposit&.id != deposit.id }
            raise AlreadyMatchedElsewhereError
          end

          # Only the transactions not already linked to THIS deposit count
          # toward the new total — re-submitting an already-linked one is a
          # no-op, not double-counted.
          to_link      = txns - already_matched
          current_total = deposit.matched_total
          new_total     = current_total + to_link.sum(&:amount)
          raise OverMatchError if new_total > deposit.amount

          reason = @notes

          to_link.each do |txn|
            link!(txn, deposit, reason: reason, running_total: current_total += txn.amount)
            linked << txn
          end
        end

        Result.new(ok: true, transaction: txns.first, transactions: txns, error: nil)
      rescue AlreadyMatchedElsewhereError
        err("already_matched_to_another_deposit")
      rescue OverMatchError
        err("exceeds_deposit_amount")
      rescue StatementDeletedError
        err("statement_deleted")
      rescue ActiveRecord::RecordNotFound
        Result.new(ok: false, transaction: nil, transactions: [], error: I18n.t("errors.messages.not_found"))
      rescue ActiveRecord::RecordInvalid => e
        Result.new(ok: false, transaction: nil, transactions: [], error: e.message)
      rescue ActiveRecord::RecordNotUnique
        # Unique index on deposit_matches.bank_statement_transaction_id (the only
        # unique index this transaction writes to): another request claimed
        # this transaction concurrently. Any other database error propagates.
        err("already_matched_to_another_deposit")
      end

      private

      AlreadyMatchedElsewhereError = Class.new(StandardError)
      OverMatchError               = Class.new(StandardError)
      StatementDeletedError        = Class.new(StandardError)

      def link!(txn, deposit, reason:, running_total:)
        was_unmatched = !txn.matched?

        DepositMatch.create_for!(till_deposit: deposit, bank_statement_transaction: txn, matched_by: @actor)

        txn.update!(
          match_method:     "manual",
          match_confidence: 100,
          match_reason:     reason,
          match_notes:      @notes,
          status:           "verified"
        )

        if was_unmatched
          txn.bank_statement.increment!(:matched_rows)
          txn.bank_statement.decrement!(:unmatched_rows)
        end

        log_audit(
          actor:     @actor,
          auditable: txn,
          action:    :manual_match,
          metadata:  {
            till_deposit_id: deposit.id,
            confidence:      100,
            reason:          reason,
            notes:           @notes,
            matched_amount:  txn.amount.to_s,
            running_total:   running_total.to_s,
            deposit_amount:  deposit.amount.to_s
          }
        )
      end

      def err(key)
        Result.new(ok: false, transaction: nil, transactions: [],
                   error: I18n.t("finance.bank_statements.errors.#{key}"))
      end
    end
  end
end
