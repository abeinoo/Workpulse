module Finance
  module BankStatements
    # Marks a BankStatementTransaction as ignored.
    #
    # If the transaction was previously matched, the match is cleared so the
    # associated TillDeposit is released and can be matched to another transaction.
    # Counters on the parent BankStatement are adjusted accordingly.
    class Ignorer
      include AuditLoggable

      Result = Struct.new(:ok, :transaction, :error, keyword_init: true) do
        def ok? = ok
      end

      # metadata: extra audit context from a caller (e.g. BulkIgnorer's batch tag).
      def self.call(transaction_id, actor:, reason: nil, metadata: {})
        new(transaction_id, actor: actor, reason: reason, metadata: metadata).call
      end

      def initialize(transaction_id, actor:, reason: nil, metadata: {})
        @transaction_id = transaction_id
        @actor          = actor
        @reason         = reason
        @metadata       = metadata
      end

      def call
        txn = BankStatementTransaction
                .where(business: @actor.business)
                .find(@transaction_id)

        return err("already_ignored") if txn.ignored?

        ActiveRecord::Base.transaction do
          was_matched   = txn.matched?
          was_unmatched = !txn.matched?

          txn.deposit_matches.destroy_all if was_matched

          attrs = { status: "ignored", ignored_reason: @reason }
          attrs.merge!(match_method: nil, match_notes: nil) if was_matched

          txn.update!(attrs)

          # Adjust counters to reflect this transaction leaving its previous bucket.
          # Ignored rows are counted in neither matched_rows nor unmatched_rows.
          if was_matched
            txn.bank_statement.decrement!(:matched_rows)
          elsif was_unmatched
            txn.bank_statement.decrement!(:unmatched_rows)
          end

          log_audit(
            actor:     @actor,
            auditable: txn,
            action:    :ignored,
            metadata:  { reason: @reason, was_matched: was_matched, **@metadata }
          )
        end

        Result.new(ok: true, transaction: txn, error: nil)
      rescue ActiveRecord::RecordNotFound
        Result.new(ok: false, transaction: nil, error: I18n.t("errors.messages.not_found"))
      rescue ActiveRecord::RecordInvalid => e
        Result.new(ok: false, transaction: nil, error: e.message)
      end

      private

      def err(key)
        Result.new(ok: false, transaction: nil,
                   error: I18n.t("finance.bank_statements.errors.#{key}"))
      end
    end
  end
end
