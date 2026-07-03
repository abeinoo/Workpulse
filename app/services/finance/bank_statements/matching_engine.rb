module Finance
  module BankStatements
    # Auto-matches BankStatementTransactions against TillDeposits.
    #
    # Matching priority:
    #   Level 1 — Reference Number: both present and equal → verified (auto_reference)
    #   Level 2 — Amount + Date: same amount and same calendar date → verified (auto_amount_date)
    #             If amount differs but dates match → amount_mismatch
    #             If amounts match but dates differ → date_mismatch
    #   Unmatched after both levels → unexpected
    #
    # After matching, counters (matched_rows, unmatched_rows) are recomputed from the
    # database rather than maintained incrementally. This prevents drift from any
    # partial failure, concurrent update, or rematch run.
    #
    # Every auto-matched transaction receives an AuditLog entry matching the
    # per-event trail created by ManualMatcher.
    class MatchingEngine
      include AuditLoggable

      REMATCHABLE_STATUSES = %w[pending unexpected amount_mismatch date_mismatch needs_reverification].freeze

      Result = Struct.new(:ok, :matched, :unmatched, :error, keyword_init: true) do
        def ok? = ok
      end

      def self.call(bank_statement_id, actor:, rematch: false)
        new(bank_statement_id, actor: actor, rematch: rematch).call
      end

      def initialize(bank_statement_id, actor:, rematch: false)
        @bank_statement_id = bank_statement_id
        @actor             = actor
        @rematch           = rematch
      end

      def call
        statement    = BankStatement.where(business: @actor.business).find(@bank_statement_id)
        transactions = load_transactions(statement)

        return Result.new(ok: true, matched: 0, unmatched: 0) if transactions.empty?

        matched   = 0
        unmatched = 0

        ActiveRecord::Base.transaction do
          if @rematch
            statement.bank_statement_transactions
                     .where(status: REMATCHABLE_STATUSES)
                     .where.not(matched_till_deposit_id: nil)
                     .update_all(
                       matched_till_deposit_id:    nil,
                       match_method:               nil,
                       matched_by_id:              nil,
                       matched_at:                 nil,
                       status:                     "pending",
                       snapshot_deposit_amount:    nil,
                       snapshot_deposit_date:      nil,
                       snapshot_deposit_reference: nil
                     )
          end

          deposits = load_deposits(statement)

          by_reference        = build_reference_index(deposits)
          by_amount           = build_amount_date_index(deposits)
          matched_deposit_ids = Set.new

          # Pre-build sets for O(1) near-miss detection instead of O(N) scans.
          deposit_amounts = Set.new(deposits.map(&:amount))
          deposit_dates   = Set.new(deposits.map { |d| d.deposited_at.to_date })

          transactions.each do |txn|
            deposit = nil
            method  = nil

            # Level 1 — reference number
            if txn.reference_number.present?
              candidate = by_reference[normalize_ref(txn.reference_number)]
              if candidate && !matched_deposit_ids.include?(candidate.id)
                deposit = candidate
                method  = "auto_reference"
              end
            end

            # Level 2 — amount + date
            if deposit.nil?
              key        = [ txn.amount, txn.transaction_date ]
              candidates = (by_amount[key] || []).reject { |d| matched_deposit_ids.include?(d.id) }
              if candidates.one?
                deposit = candidates.first
                method  = "auto_amount_date"
              end
            end

            if deposit
              matched_deposit_ids << deposit.id
              status = derive_status(txn, deposit, method)
              txn.update!(
                matched_till_deposit_id:    deposit.id,
                match_method:               method,
                matched_at:                 Time.current,
                status:                     status,
                snapshot_deposit_amount:    deposit.amount,
                snapshot_deposit_date:      deposit.deposited_at.to_date,
                snapshot_deposit_reference: deposit.reference
              )
              log_audit(
                actor:     @actor,
                auditable: txn,
                action:    :auto_matched,
                metadata:  {
                  match_method:    method,
                  till_deposit_id: deposit.id,
                  status:          status
                }
              )
              matched += 1
            else
              near_miss_status = detect_near_miss(txn, deposit_amounts, deposit_dates)
              txn.update!(status: near_miss_status)
              unmatched += 1
            end
          end

          # Recompute counters from the database so they reflect the true state
          # of all transactions (including verified/ignored rows not touched here).
          txn_scope = statement.bank_statement_transactions
          statement.update!(
            matched_rows:   txn_scope.where.not(matched_till_deposit_id: nil).count,
            unmatched_rows: txn_scope.where(matched_till_deposit_id: nil)
                                     .where.not(status: "ignored")
                                     .count
          )
        end # transaction

        Result.new(ok: true, matched: matched, unmatched: unmatched, error: nil)
      rescue => e
        Rails.logger.error("[BankStatements::MatchingEngine] #{e.class}: #{e.message}")
        Result.new(ok: false, matched: 0, unmatched: 0, error: e.message)
      end

      private

      def load_transactions(statement)
        if @rematch
          statement.bank_statement_transactions.where(status: REMATCHABLE_STATUSES).to_a
        else
          statement.bank_statement_transactions.pending.to_a
        end
      end

      def load_deposits(statement)
        scope = TillDeposit
          .joins(:daily_reconciliation)
          .where(daily_reconciliations: { business_id: @actor.business.id })
          .where(daily_reconciliations: { business_date: statement.statement_from..statement.statement_to })
          .where(voided_at: nil)
          .where.missing(:bank_statement_transaction)

        if statement.branch_id?
          scope = scope.where(daily_reconciliations: { branch_id: statement.branch_id })
        end

        scope.to_a
      end

      def build_reference_index(deposits)
        deposits.each_with_object({}) do |d, h|
          next if d.reference.blank?
          h[normalize_ref(d.reference)] = d
        end
      end

      def build_amount_date_index(deposits)
        deposits.each_with_object(Hash.new { |hh, k| hh[k] = [] }) do |d, h|
          h[[ d.amount, d.deposited_at.to_date ]] << d
        end
      end

      def normalize_ref(str)
        str.to_s.strip.downcase.gsub(/\s+/, "")
      end

      def derive_status(txn, deposit, method)
        return "verified" if method == "auto_reference"

        amounts_match = txn.amount == deposit.amount
        dates_match   = txn.transaction_date == deposit.deposited_at.to_date

        if amounts_match && dates_match
          "verified"
        elsif !amounts_match && dates_match
          "amount_mismatch"
        elsif amounts_match && !dates_match
          "date_mismatch"
        else
          "amount_mismatch"
        end
      end

      # O(1) near-miss detection using pre-built sets of all deposit amounts/dates.
      def detect_near_miss(txn, deposit_amounts, deposit_dates)
        same_amount = deposit_amounts.include?(txn.amount)
        same_date   = deposit_dates.include?(txn.transaction_date)

        if same_amount && !same_date
          "date_mismatch"
        elsif same_date && !same_amount
          "amount_mismatch"
        else
          "unexpected"
        end
      end
    end
  end
end
