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

      def self.call(transaction_id, actor:, reason: nil)
        new(transaction_id, actor: actor, reason: reason).call
      end

      def initialize(transaction_id, actor:, reason: nil)
        @transaction_id = transaction_id
        @actor          = actor
        @reason         = reason
      end

      def call
        txn = BankStatementTransaction
                .where(business: @actor.business)
                .find(@transaction_id)

        return err("already_ignored") if txn.ignored?

        ActiveRecord::Base.transaction do
          was_matched   = txn.matched?
          was_unmatched = !txn.matched?

          attrs = { status: "ignored", ignored_reason: @reason }

          if was_matched
            attrs.merge!(
              matched_till_deposit_id:    nil,
              match_method:               nil,
              matched_by:                 nil,
              matched_at:                 nil,
              match_notes:                nil,
              snapshot_deposit_amount:    nil,
              snapshot_deposit_date:      nil,
              snapshot_deposit_reference: nil
            )
          end

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
            metadata:  { reason: @reason, was_matched: was_matched }
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
