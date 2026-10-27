module Finance
  module BankStatements
    # Ignores many bank transactions at once from Deposit Verification —
    # removes them from the active verification workflow without deleting
    # anything. All-or-nothing: either every given transaction is ignored or
    # none is, and the error names what blocked the batch.
    #
    # Eligibility is re-checked here under row locks, never trusted from the
    # browser. Only an UNMATCHED transaction of an active statement, in a
    # status still awaiting a decision (ELIGIBLE_STATUSES), qualifies: ignoring
    # a matched transaction would release its deposit (Ignorer clears the
    # match), which must stay an explicit Unmatch, one line at a time.
    #
    # Each transaction goes through Ignorer — same status, counters and audit
    # (action :ignored, with the reason, bulk: true and the batch size). Locks
    # the transactions by id, the order Deleter / ManualMatcher / MatchingEngine
    # use. Reversible line by line with Unignorer.
    class BulkIgnorer
      ELIGIBLE_STATUSES = %w[unexpected amount_mismatch date_mismatch needs_manual_review].freeze
      MAX_TRANSACTIONS  = 500

      Result = Struct.new(:ok, :ignored_count, :error, keyword_init: true) do
        def ok? = ok
      end

      BatchError = Class.new(StandardError)

      # The eligibility rule as a relation — used by Deposit Verification to
      # mark selectable rows and resolve "all matching" (always re-checked here).
      def self.eligible(scope)
        scope.joins(:bank_statement)
             .where(bank_statements: { deleted_at: nil })
             .where(status: ELIGIBLE_STATUSES)
             .where.missing(:deposit_matches)
      end

      def initialize(transaction_ids:, actor:, reason:)
        @ids    = Array(transaction_ids).filter_map { |id| Integer(id, exception: false) }.select(&:positive?).uniq
        @actor  = actor
        @reason = reason.to_s.strip.presence
      end

      def call
        return error(:bulk_ignore_reason_required) if @reason.nil?
        return error(:bulk_ignore_none_selected) if @ids.empty?
        return error(:bulk_ignore_too_many, max: MAX_TRANSACTIONS) if @ids.size > MAX_TRANSACTIONS

        ActiveRecord::Base.transaction do
          txns = BankStatementTransaction.where(business_id: @actor.business_id, id: @ids)
                                         .order(:id).lock.includes(:bank_statement).to_a
          raise BatchError, message(:bulk_ignore_unavailable) if txns.size != @ids.size

          eligible_ids = self.class.eligible(BankStatementTransaction.where(id: @ids)).pluck(:id).to_set
          blocked = txns.reject { |t| eligible_ids.include?(t.id) }
          raise BatchError, message(:bulk_ignore_ineligible, ids: blocked.map { |t| "##{t.id}" }.join("، ")) if blocked.any?

          txns.each do |txn|
            result = Ignorer.call(txn.id, actor: @actor, reason: @reason,
                                          metadata: { bulk: true, batch_size: txns.size })
            raise BatchError, "##{txn.id}: #{result.error}" unless result.ok?
          end
        end

        Result.new(ok: true, ignored_count: @ids.size, error: nil)
      rescue BatchError, ActiveRecord::RecordInvalid => e
        Result.new(ok: false, ignored_count: 0, error: e.message)
      end

      private

      def message(key, **args) = I18n.t("finance.bank_statements.errors.#{key}", **args)

      def error(key, **args) = Result.new(ok: false, ignored_count: 0, error: message(key, **args))
    end
  end
end
