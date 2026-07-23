module Finance
  module BankStatements
    # Manually links a BankStatementTransaction to a TillDeposit.
    # Clears any previous match on the transaction before setting the new one.
    # Increments/decrements BankStatement counters accordingly.
    #
    # The deposit is locked with FOR UPDATE inside the transaction to prevent two
    # concurrent requests from matching the same deposit simultaneously (TOCTOU).
    class ManualMatcher
      include AuditLoggable

      Result = Struct.new(:ok, :transaction, :error, keyword_init: true) do
        def ok? = ok
      end

      def self.call(transaction_id, till_deposit_id:, actor:, notes: nil)
        new(transaction_id, till_deposit_id: till_deposit_id, actor: actor, notes: notes).call
      end

      def initialize(transaction_id, till_deposit_id:, actor:, notes: nil)
        @transaction_id  = transaction_id
        @till_deposit_id = till_deposit_id
        @actor           = actor
        @notes           = notes
      end

      def call
        txn = BankStatementTransaction
                .where(business: @actor.business)
                .find(@transaction_id)

        ActiveRecord::Base.transaction do
          # Lock the deposit row before checking availability to eliminate the
          # TOCTOU window between "is this deposit free?" and "claim it".
          deposit = TillDeposit
                      .joins(:daily_reconciliation)
                      .where(daily_reconciliations: { business_id: @actor.business.id })
                      .where(voided_at: nil)
                      .lock
                      .find(@till_deposit_id)

          existing = deposit.bank_statement_transaction
          if existing.present? && existing.id != txn.id
            raise AlreadyMatchedError
          end

          # Counter update: only changes when going from unmatched → matched.
          # Switching from deposit A to deposit B is net-zero (stays matched).
          was_unmatched = txn.matched_till_deposit_id.nil?

          reason = @notes.presence ||
                   I18n.t("finance.bank_statement_transactions.match_reasons.manual", actor: @actor.full_name)

          txn.update!(
            matched_till_deposit_id:    deposit.id,
            match_method:               "manual",
            match_confidence:           100,
            match_reason:               reason,
            matched_by:                 @actor,
            matched_at:                 Time.current,
            match_notes:                @notes,
            status:                     "verified",
            snapshot_deposit_amount:    deposit.amount,
            snapshot_deposit_date:      deposit.deposited_at.to_date,
            snapshot_deposit_reference: deposit.reference
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
              notes:           @notes
            }
          )
        end

        Result.new(ok: true, transaction: txn, error: nil)
      rescue AlreadyMatchedError
        err("already_matched_to_another")
      rescue ActiveRecord::RecordNotFound
        Result.new(ok: false, transaction: nil, error: I18n.t("errors.messages.not_found"))
      rescue ActiveRecord::RecordInvalid => e
        Result.new(ok: false, transaction: nil, error: e.message)
      rescue ActiveRecord::StatementInvalid
        # Unique index violation: another request claimed this deposit concurrently.
        err("already_matched_to_another")
      end

      private

      AlreadyMatchedError = Class.new(StandardError)

      def err(key)
        Result.new(ok: false, transaction: nil,
                   error: I18n.t("finance.bank_statements.errors.#{key}"))
      end
    end
  end
end
