module Finance
  module BankStatements
    # Soft-deletes a bank statement. The statement and its transactions are kept
    # for audit; only deleted_at / deleted_by / deletion_notes are set.
    #
    # Every deposit match held by one of the statement's transactions is
    # released first, through Unmatcher's shared release step (audit action
    # released_by_statement_deletion, counters adjusted, transaction back to
    # "unexpected"). A match left on a deleted statement keeps its deposit
    # "matched" to bank evidence nobody can see any more, and the matching
    # engine never offers that deposit to another statement again.
    #
    # Locking: the statement's transactions (by id), then the statement row —
    # the same transaction-then-statement order TillDepositVoider, Unmatcher
    # and Ignorer use, so they serialize instead of deadlocking. ManualMatcher
    # and MatchingEngine lock the transactions they link and refuse a deleted
    # statement, so no match can be added behind this deletion.
    #
    # All-or-nothing: a failure releasing any match rolls back every release
    # and the deletion itself.
    class Deleter
      include AuditLoggable

      Result = Struct.new(:ok, :bank_statement, :released_count, :error, keyword_init: true) do
        def ok? = ok
      end

      def self.call(bank_statement_id, actor:, notes: nil)
        new(bank_statement_id, actor: actor, notes: notes).call
      end

      def initialize(bank_statement_id, actor:, notes: nil)
        @bank_statement_id = bank_statement_id
        @actor             = actor
        @notes             = notes
      end

      def call
        statement = BankStatement.where(business: @actor.business).find(@bank_statement_id)
        released  = 0

        ActiveRecord::Base.transaction do
          transactions = statement.bank_statement_transactions.order(:id).lock.to_a
          statement.lock!
          raise AlreadyDeletedError if statement.deleted?

          # As recorded at deletion time — the releases below decrement it.
          matched_at_deletion = statement.matched_rows

          unmatcher = Finance::BankStatements::Unmatcher.new(nil, actor: @actor)
          transactions.select(&:matched?).each do |txn|
            unmatcher.release!(txn, action: :released_by_statement_deletion,
                                    metadata: { bank_statement_id: statement.id,
                                                till_deposit_id:   txn.matched_till_deposit&.id,
                                                deletion_notes:    @notes })
            released += 1
          end

          statement.update_columns(deleted_at: Time.current, deleted_by_id: @actor.id, deletion_notes: @notes)

          log_audit(
            actor:     @actor,
            auditable: statement,
            action:    :bank_statement_deleted,
            metadata:  {
              file_name:        statement.file_name,
              statement_from:   statement.statement_from.to_s,
              statement_to:     statement.statement_to.to_s,
              total_rows:       statement.total_rows,
              matched_rows:     matched_at_deletion,
              released_matches: released,
              notes:            @notes
            }
          )
        end

        Result.new(ok: true, bank_statement: statement, released_count: released, error: nil)
      rescue AlreadyDeletedError
        Result.new(ok: false, bank_statement: statement, released_count: 0,
                   error: I18n.t("finance.bank_statements.errors.already_deleted"))
      rescue ActiveRecord::RecordInvalid => e
        Result.new(ok: false, bank_statement: statement, released_count: 0, error: e.message)
      end

      AlreadyDeletedError = Class.new(StandardError)
    end
  end
end
