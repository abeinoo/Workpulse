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

        # Re-checked under the row lock: a concurrent unmatch (or a deposit
        # void releasing this match) may have won the race, and releasing
        # twice would double-adjust the statement's counters.
        released = ActiveRecord::Base.transaction do
          txn.lock!
          next false unless txn.matched?

          release!(txn, action: :manual_unmatch, metadata: { notes: @notes })
          true
        end
        return err("not_matched") unless released

        Result.new(ok: true, transaction: txn, error: nil)
      rescue ActiveRecord::RecordNotFound
        Result.new(ok: false, transaction: nil, error: I18n.t("errors.messages.not_found"))
      rescue ActiveRecord::RecordInvalid => e
        Result.new(ok: false, transaction: nil, error: e.message)
      rescue AuditLoggable::AuditWriteFailed
        Result.new(ok: false, transaction: nil, error: I18n.t("audit_log.errors.write_failed"))
      end

      # The release step itself, shared with Finance::TillDepositVoider (which
      # frees a voided deposit's matches). Never opens its own transaction —
      # the caller must already hold one, so a failure anywhere in the
      # caller's operation rolls the release back with it.
      def release!(txn, action:, metadata: {})
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

        # Fail-closed (BUG-003): the match row is hard-deleted above, so this
        # entry is the only record of which deposit the line was matched to.
        # AuditWriteFailed rolls back the caller's whole release.
        log_audit!(
          actor:     @actor,
          auditable: txn,
          action:    action,
          metadata:  { previous_till_deposit_id: previous_deposit_id, **metadata }
        )
      end

      private

      def err(key)
        Result.new(ok: false, transaction: nil,
                   error: I18n.t("finance.bank_statements.errors.#{key}"))
      end
    end
  end
end
