module Finance
  module BankStatements
    # Reverses any match (automatic or manual) on a BankStatementTransaction,
    # returning it to "unexpected" status so it can be re-matched (by rematch
    # or by a different manual selection). Any matched_till_deposit is freed
    # immediately, since the association is cleared here.
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
          previous_deposit_id = txn.matched_till_deposit&.id

          txn.deposit_matches.destroy_all

          txn.update!(
            match_method:     nil,
            match_confidence: nil,
            match_reason:     nil,
            match_notes:      nil,
            status:           "unexpected"
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
