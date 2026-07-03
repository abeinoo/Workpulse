module Finance
  module BankStatements
    # Reverses a manual match on a BankStatementTransaction, returning it to
    # "unexpected" status. Only manual matches may be reversed this way;
    # auto-matched transactions require re-running the matching engine.
    class Unmatcher
      include AuditLoggable

      Result = Struct.new(:ok, :transaction, :error, keyword_init: true) do
        def ok? = ok
      end

      def self.call(transaction_id, actor:, notes: nil)
        new(transaction_id, actor: actor, notes: notes).call
      end

      def initialize(transaction_id, actor:, notes: nil)
        @transaction_id = transaction_id
        @actor          = actor
        @notes          = notes
      end

      def call
        txn = BankStatementTransaction
                .where(business: @actor.business)
                .find(@transaction_id)

        return err("not_matched") unless txn.matched?

        ActiveRecord::Base.transaction do
          previous_deposit_id = txn.matched_till_deposit_id

          txn.update!(
            matched_till_deposit_id:    nil,
            match_method:               nil,
            matched_by:                 nil,
            matched_at:                 nil,
            match_notes:                nil,
            status:                     "unexpected",
            snapshot_deposit_amount:    nil,
            snapshot_deposit_date:      nil,
            snapshot_deposit_reference: nil
          )

          txn.bank_statement.decrement!(:matched_rows)
          txn.bank_statement.increment!(:unmatched_rows)

          log_audit(
            actor:     @actor,
            auditable: txn,
            action:    :manual_unmatch,
            metadata:  {
              previous_till_deposit_id: previous_deposit_id,
              notes:                    @notes
            }
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
