module Finance
  module BankStatements
    # Reverses Ignorer: an ignored bank transaction returns to the verification
    # workflow as "unexpected" (no deposit linked — Ignorer never leaves one),
    # counted again in its statement's unmatched_rows. A Rematch of the
    # statement then re-classifies it; nothing is matched here.
    #
    # A reason is required and audited (action :unignored, with the reason the
    # line was ignored for). Lines of a deleted statement stay as they are.
    # Locks the transaction, then its statement — the order every other
    # bank-match service uses.
    class Unignorer
      include AuditLoggable

      Result = Struct.new(:ok, :transaction, :error, keyword_init: true) do
        def ok? = ok
      end

      def self.call(transaction_id, actor:, reason:)
        new(transaction_id, actor: actor, reason: reason).call
      end

      def initialize(transaction_id, actor:, reason:)
        @transaction_id = transaction_id
        @actor          = actor
        @reason         = reason.to_s.strip.presence
      end

      def call
        return err("unignore_reason_required") if @reason.nil?

        txn = nil
        error = nil
        ActiveRecord::Base.transaction do
          txn = BankStatementTransaction.where(business: @actor.business).lock.find(@transaction_id)
          statement = txn.bank_statement
          statement.lock!

          if statement.deleted?
            error = "statement_deleted"
            next
          end
          unless txn.ignored?
            error = "not_ignored"
            next
          end

          previous_reason = txn.ignored_reason
          txn.update!(status: "unexpected", ignored_reason: nil)
          statement.increment!(:unmatched_rows)

          log_audit(actor: @actor, auditable: txn, action: :unignored,
                    metadata: { reason: @reason, previous_ignored_reason: previous_reason })
        end
        return err(error) if error

        Result.new(ok: true, transaction: txn, error: nil)
      rescue ActiveRecord::RecordNotFound
        Result.new(ok: false, transaction: nil, error: I18n.t("errors.messages.not_found"))
      rescue ActiveRecord::RecordInvalid => e
        Result.new(ok: false, transaction: nil, error: e.message)
      end

      private

      def err(key)
        Result.new(ok: false, transaction: nil, error: I18n.t("finance.bank_statements.errors.#{key}"))
      end
    end
  end
end
