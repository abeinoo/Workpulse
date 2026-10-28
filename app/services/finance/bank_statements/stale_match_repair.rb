module Finance
  module BankStatements
    # Finds — and, only on explicit request, releases — deposit matches left on
    # transactions of soft-deleted bank statements (statements deleted before
    # Finance::BankStatements::Deleter released matches on deletion).
    #
    # Read-only by default. #report lists every stale match of a business with a
    # safety verdict and never writes (its transaction is SET READ ONLY).
    # #repair! releases only the match ids it is given, and only when
    # execute: true; without it, it reports what it would do. There is no "all"
    # mode: every match to release is named.
    #
    # Each release reuses Unmatcher#release! (same counters, status, and audit
    # action as a deletion: released_by_statement_deletion, plus repair: true)
    # in its own transaction, locking the transaction row then its statement —
    # Deleter's order — and re-checking safety after the lock. A record that is
    # not unambiguously stale is skipped, never released.
    class StaleMatchRepair
      Item = Struct.new(:match_id, :transaction_id, :statement_id, :deposit_id, :daily_reconciliation_id,
                        :amount, :transaction_status, :verdict, :reason, keyword_init: true) do
        def eligible? = verdict == :eligible
      end

      Outcome = Struct.new(:match_id, :result, :reason, keyword_init: true)

      def initialize(business:, actor: nil)
        @business = business
        @actor    = actor
      end

      # Every stale match of the business (optionally only match_ids), each
      # with :eligible or :unsafe and the reason. Never writes.
      def report(match_ids: nil)
        items = nil
        fresh = !ActiveRecord::Base.connection.transaction_open?
        ActiveRecord::Base.transaction do
          # Database-enforced when this starts the transaction (SET TRANSACTION
          # must come first); Rails' write guard applies either way.
          ActiveRecord::Base.connection.execute("SET TRANSACTION READ ONLY") if fresh
          ActiveRecord::Base.while_preventing_writes do
            scope = stale_scope
            scope = scope.where(id: match_ids) if match_ids
            items = scope.includes(:till_deposit, bank_statement_transaction: :bank_statement)
                         .order(:id).map { |m| assess(m) }
          end
          raise ActiveRecord::Rollback if fresh
        end
        items
      end

      # Releases the named matches when execute: true; otherwise a dry run
      # returning what would happen. Returns one Outcome per requested id:
      # :released, :would_release, :skipped (with reason) or :failed (with error).
      def repair!(match_ids:, execute: false)
        ids = Array(match_ids).map { |id| Integer(id) }.uniq
        raise ArgumentError, "match_ids must name the matches to repair" if ids.empty?
        raise ArgumentError, "an actor from this business is required" if execute && @actor&.business_id != @business.id

        ids.map { |id| execute ? release_one(id) : preview_one(id) }
      end

      private

      def stale_scope
        DepositMatch.joins(bank_statement_transaction: :bank_statement)
                    .where(bank_statement_transactions: { business_id: @business.id })
                    .where.not(bank_statements: { deleted_at: nil })
      end

      def preview_one(id)
        item = report(match_ids: [ id ]).first
        return Outcome.new(match_id: id, result: :skipped, reason: "not a stale match (already released or not found)") unless item
        return Outcome.new(match_id: id, result: :skipped, reason: item.reason) unless item.eligible?

        Outcome.new(match_id: id, result: :would_release, reason: nil)
      end

      def release_one(id)
        outcome = nil
        ActiveRecord::Base.transaction do
          match = DepositMatch.find_by(id: id)
          unless match
            outcome = Outcome.new(match_id: id, result: :skipped, reason: "not a stale match (already released or not found)")
            next
          end

          txn = BankStatementTransaction.lock.find(match.bank_statement_transaction_id)
          txn.bank_statement.lock!
          match = DepositMatch.includes(:till_deposit).find_by(id: id) # re-read under the lock
          item  = match && stale_scope.exists?(id: id) ? assess(match) : nil

          if item.nil?
            outcome = Outcome.new(match_id: id, result: :skipped, reason: "not a stale match (already released or not found)")
          elsif !item.eligible?
            outcome = Outcome.new(match_id: id, result: :skipped, reason: item.reason)
          else
            Finance::BankStatements::Unmatcher.new(nil, actor: @actor).release!(
              txn, action: :released_by_statement_deletion,
                   metadata: { bank_statement_id: txn.bank_statement_id, till_deposit_id: item.deposit_id,
                               repair: true, deletion_notes: nil }
            )
            outcome = Outcome.new(match_id: id, result: :released, reason: nil)
          end
        end
        outcome
      rescue ActiveRecord::ActiveRecordError => e
        Outcome.new(match_id: id, result: :failed, reason: "#{e.class}: #{e.message}")
      end

      def assess(match)
        txn     = match.bank_statement_transaction
        deposit = match.till_deposit
        reason  = unsafe_reason(match, txn, deposit)

        Item.new(match_id: match.id, transaction_id: txn.id, statement_id: txn.bank_statement_id,
                 deposit_id: deposit.id, daily_reconciliation_id: deposit.daily_reconciliation_id,
                 amount: match.matched_amount, transaction_status: txn.status,
                 verdict: reason ? :unsafe : :eligible, reason: reason)
      end

      # Anything ambiguous is reported and left alone.
      def unsafe_reason(match, txn, deposit)
        return "statement is not deleted" unless txn.bank_statement.deleted?
        return "deposit belongs to another business" unless deposit.daily_reconciliation.business_id == @business.id
        return "deposit is voided — review the void separately" if deposit.voided?
        return "transaction holds more than one match" if txn.deposit_matches.count > 1
        return "matched amount differs from the transaction amount" unless match.matched_amount == txn.amount
        return "deposit is also matched to other transactions" if deposit.deposit_matches.where.not(id: match.id).exists?

        nil
      end
    end
  end
end
