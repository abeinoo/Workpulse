module Finance
  module DepositVerification
    # Production matching engine for BankStatementTransaction <-> TillDeposit
    # reconciliation. Replaces the earlier Finance::BankStatements::MatchingEngine,
    # which matched via `candidates.one?` — refusing to match at all whenever a
    # transaction had more than one same-amount/same-date candidate. That made
    # duplicate transactions (two "+300" rows on the same day) fail every time:
    # both candidates were visible on both attempts, `.one?` was false for
    # both, and both transactions fell through to "unexpected" even though a
    # perfectly good 1:1 pairing existed. See MatchingEngineSpec for the
    # regression test.
    #
    # ── Algorithm ──────────────────────────────────────────────────────────
    #
    # Transactions and deposits are loaded once into two arrays — the "pool" —
    # and matching *consumes* from both: once a transaction or deposit is
    # assigned, it is removed and can never be assigned again. No `find_by`,
    # no "first matching record" — every decision is made by comparing the
    # full remaining candidate set.
    #
    # Matching runs in five priority tiers (SCORE_* constants below). Within
    # each tier, remaining transactions are grouped into buckets that share a
    # matching key (reference number; amount+date; amount, for the ±1‑day and
    # amount‑only tiers) together with the pool deposits eligible for that
    # bucket. Each bucket is then resolved by comparing **counts**:
    #
    #   txns.size == deposits.size  → exact 1:1 — every deposit in this bucket
    #                                  is interchangeable with every other, so
    #                                  the aggregate outcome is unambiguous
    #                                  regardless of which specific row pairs
    #                                  with which. Auto-match all pairs,
    #                                  deterministically ordered by id. This is
    #                                  what makes "300/300/300 vs 300/300/300"
    #                                  resolve as 3 clean matches instead of 3
    #                                  refusals.
    #
    #   txns.size >  deposits.size  → deposit deficit. Every available deposit
    #                                  is used exactly once (deterministically,
    #                                  lowest id first); the excess transactions
    #                                  have no candidate left and fall through
    #                                  to the next tier (or to "no match" if
    #                                  none remains). This is "300,300 vs 300 →
    #                                  1 matched, 1 unmatched".
    #
    #   txns.size <  deposits.size  → deposit surplus: more equally-good
    #                                  candidates exist than transactions need,
    #                                  so *which* specific deposit is correct is
    #                                  genuinely ambiguous — it is not safe to
    #                                  guess. We first attempt to break the tie
    #                                  with description/notes similarity
    #                                  (SCORE_DESCRIPTION_SIMILARITY); anything
    #                                  still unresolved is marked
    #                                  "needs_manual_review" and every deposit
    #                                  in the bucket is left in the pool
    #                                  (untouched) as a candidate for the
    #                                  manual-match modal.
    #
    # Transactions with no candidate at any tier are classified "unexpected"
    # (or a mismatch hint) exactly as before.
    class MatchingEngine
      include AuditLoggable

      REMATCHABLE_STATUSES = %w[
        pending unexpected amount_mismatch date_mismatch needs_reverification needs_manual_review
      ].freeze

      SCORE_REFERENCE               = 100
      SCORE_AMOUNT_DATE             = 90
      SCORE_AMOUNT_NEAR_DATE        = 80
      SCORE_AMOUNT_ONLY             = 70
      SCORE_DESCRIPTION_SIMILARITY  = 60

      METHOD_FOR_SCORE = {
        SCORE_REFERENCE              => "auto_reference",
        SCORE_AMOUNT_DATE            => "auto_amount_date",
        SCORE_AMOUNT_NEAR_DATE       => "auto_amount_near_date",
        SCORE_AMOUNT_ONLY            => "auto_amount_only",
        SCORE_DESCRIPTION_SIMILARITY => "auto_description_similarity"
      }.freeze

      NEAR_DATE_TOLERANCE_DAYS = 1

      # Token-overlap similarity (0-100) a transaction's description and a
      # deposit's notes must clear to break a same-amount surplus tie.
      DESCRIPTION_SIMILARITY_THRESHOLD = 60

      Result = Struct.new(:ok, :matched, :unmatched, :needs_review, :error, keyword_init: true) do
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
        statement = BankStatement.where(business: @actor.business).find(@bank_statement_id)

        matched = unmatched = needs_review = 0
        @previous_outcomes = {}

        ActiveRecord::Base.transaction do
          if @rematch
            capture_previous_outcomes!(statement)
            reset_rematchable!(statement)
          end

          # Deterministic processing order — by id — so re-running the engine
          # against unchanged data always produces the same pairing.
          @pending = load_transactions(statement).sort_by(&:id)
          @pool    = load_deposits(statement).sort_by(&:id)

          # Snapshots of the full initial pool, used only for classifying
          # transactions that end up with no match (near-miss hints) — never
          # mutated, unlike @pool.
          all_deposit_amounts = @pool.map(&:amount).to_set
          all_deposit_dates   = @pool.map { |d| d.deposited_at.to_date }.to_set

          run_reference_tier!
          run_exact_date_tier!
          run_near_date_tier!
          run_amount_only_tier!

          # Anything still pending after every tier had no usable candidate.
          @pending.each do |txn|
            classify_no_match!(txn, all_deposit_amounts, all_deposit_dates)
          end

          # Recompute counters from the database rather than tallying in
          # memory, so they reflect the true state of every transaction
          # (including rows untouched by this run, e.g. already verified).
          txn_scope = statement.bank_statement_transactions
          matched      = txn_scope.where.not(matched_till_deposit_id: nil).count
          needs_review = txn_scope.where(status: "needs_manual_review").count
          unmatched    = txn_scope.where(matched_till_deposit_id: nil)
                                  .where.not(status: %w[ignored needs_manual_review])
                                  .count

          statement.update!(
            matched_rows:   matched,
            unmatched_rows: unmatched + needs_review
          )
        end

        Result.new(ok: true, matched: matched, unmatched: unmatched, needs_review: needs_review, error: nil)
      rescue => e
        Rails.logger.error("[DepositVerification::MatchingEngine] #{e.class}: #{e.message}")
        Result.new(ok: false, matched: 0, unmatched: 0, needs_review: 0, error: e.message)
      end

      private

      attr_reader :pending, :pool

      # ── Tier runners ─────────────────────────────────────────────────────

      def run_reference_tier!
        buckets = {}
        @pending.each do |txn|
          ref = normalize_ref(txn.reference_number)
          next if ref.blank?
          (buckets[ref] ||= []) << txn
        end

        buckets.each do |ref, txns|
          deposits = @pool.select { |d| normalize_ref(d.reference) == ref }
          next if deposits.empty?

          resolve_bucket!(txns, deposits, SCORE_REFERENCE)
        end
      end

      def run_exact_date_tier!
        buckets = {}
        @pending.each do |txn|
          key = [ txn.amount, txn.transaction_date ]
          (buckets[key] ||= []) << txn
        end

        buckets.each do |(amount, date), txns|
          deposits = @pool.select { |d| d.amount == amount && d.deposited_at.to_date == date }
          next if deposits.empty?

          resolve_bucket!(txns, deposits, SCORE_AMOUNT_DATE)
        end
      end

      def run_near_date_tier!
        @pending.group_by(&:amount).each do |amount, txns|
          next if txns.empty?

          deposits = @pool.select do |d|
            d.amount == amount &&
              txns.any? { |t| (d.deposited_at.to_date - t.transaction_date).to_i.abs <= NEAR_DATE_TOLERANCE_DAYS }
          end
          next if deposits.empty?

          resolve_bucket!(txns, deposits, SCORE_AMOUNT_NEAR_DATE)
        end
      end

      def run_amount_only_tier!
        @pending.group_by(&:amount).each do |amount, txns|
          next if txns.empty?

          deposits = @pool.select { |d| d.amount == amount }
          next if deposits.empty?

          resolve_bucket!(txns, deposits, SCORE_AMOUNT_ONLY)
        end
      end

      # ── Bucket resolution: exact / deficit / surplus ────────────────────

      def resolve_bucket!(txns, deposits, score)
        txns     = txns.sort_by(&:id)
        deposits = deposits.sort_by(&:id)

        if txns.size == deposits.size
          txns.zip(deposits).each { |txn, dep| commit_match!(txn, dep, score) }
        elsif txns.size > deposits.size
          # Deficit: deposits are the scarce resource here — every deposit is
          # used exactly once, deterministically (lowest id first); the excess
          # transactions have no candidate left at this tier and fall through
          # to the next one (or to "no match" if none remains).
          txns.first(deposits.size).zip(deposits).each { |txn, dep| commit_match!(txn, dep, score) }
        else
          resolve_surplus!(txns, deposits, score)
        end
      end

      # More equally-eligible deposits than transactions: try to break the tie
      # with description/notes similarity; anything left over is genuinely
      # ambiguous and goes to manual review with every remaining bucket
      # deposit shown as a candidate.
      def resolve_surplus!(txns, deposits, score)
        remaining_deposits = deposits.dup

        txns.each do |txn|
          scored = remaining_deposits.filter_map do |dep|
            similarity = description_similarity(txn.description, dep.notes)
            [ dep, similarity ] if similarity >= DESCRIPTION_SIMILARITY_THRESHOLD
          end

          top = scored.max_by { |_, similarity| similarity }
          unique_top = top && scored.count { |_, s| s == top.last } == 1

          if unique_top
            dep = top.first
            commit_match!(txn, dep, SCORE_DESCRIPTION_SIMILARITY)
            remaining_deposits.delete(dep)
          else
            mark_needs_review!(txn, remaining_deposits, score)
          end
        end
      end

      # ── Committing outcomes ──────────────────────────────────────────────

      def commit_match!(txn, deposit, score)
        method = METHOD_FOR_SCORE.fetch(score)
        status = derive_status(txn, deposit)
        reason = match_reason(method, txn, deposit)

        txn.update!(
          matched_till_deposit_id:    deposit.id,
          match_method:               method,
          match_confidence:           score,
          match_reason:               reason,
          matched_by:                 nil,
          matched_at:                 Time.current,
          status:                     status,
          snapshot_deposit_amount:    deposit.amount,
          snapshot_deposit_date:      deposit.deposited_at.to_date,
          snapshot_deposit_reference: deposit.reference
        )

        # Idempotency: a rematch that reproduces the exact same outcome for a
        # transaction (same deposit, same method, same status) does not add a
        # new audit entry — only a genuine change to the decision is recorded.
        # Without this, running rematch repeatedly against unchanged data would
        # silently pile up identical "auto_matched" rows forever.
        if outcome_changed?(txn, deposit_id: deposit.id, method: method, status: status)
          log_audit(
            actor:     @actor,
            auditable: txn,
            action:    :auto_matched,
            metadata:  {
              match_method:     method,
              confidence:       score,
              reason:           reason,
              till_deposit_id:  deposit.id,
              status:           status
            }
          )
        end

        @pending.delete(txn)
        @pool.delete(deposit)
      end

      def mark_needs_review!(txn, candidate_deposits, score)
        # Snapshot the candidates' own attributes at decision time (not just
        # their ids) so the audit trail and the review UI can explain the
        # ambiguity even if a candidate deposit is later edited or voided.
        candidates = candidate_deposits.map do |d|
          { till_deposit_id: d.id, amount: d.amount.to_s, date: d.deposited_at.to_date.to_s, reference: d.reference }
        end
        reason = I18n.t("finance.bank_statement_transactions.match_reasons.needs_manual_review",
                         count: candidates.size)

        txn.update!(status: "needs_manual_review", match_confidence: score, match_reason: reason)

        if outcome_changed?(txn, deposit_id: nil, method: nil, status: "needs_manual_review")
          log_audit(
            actor:     @actor,
            auditable: txn,
            action:    :needs_manual_review,
            metadata:  {
              confidence:  score,
              reason:      reason,
              candidates:  candidates
            }
          )
        end

        @pending.delete(txn)
      end

      def classify_no_match!(txn, all_deposit_amounts, all_deposit_dates)
        same_amount = all_deposit_amounts.include?(txn.amount)
        same_date   = all_deposit_dates.include?(txn.transaction_date)

        status = if same_amount && !same_date
          "date_mismatch"
        elsif same_date && !same_amount
          "amount_mismatch"
        else
          "unexpected"
        end

        txn.update!(status: status, match_confidence: nil, match_reason: nil)
      end

      # True when the transaction's previously-recorded outcome (before this
      # rematch run reset it) differs from the outcome we're about to commit.
      # On a first-time (non-rematch) run there is no previous outcome, so
      # everything counts as a change.
      def outcome_changed?(txn, deposit_id:, method:, status:)
        previous = @previous_outcomes[txn.id]
        return true if previous.nil?

        previous != [ deposit_id, method, status ]
      end

      def match_reason(method, txn, deposit)
        case method
        when "auto_reference"
          I18n.t("finance.bank_statement_transactions.match_reasons.auto_reference",
                 reference: txn.reference_number)
        when "auto_amount_date"
          I18n.t("finance.bank_statement_transactions.match_reasons.auto_amount_date",
                 amount: txn.amount, date: I18n.l(txn.transaction_date))
        when "auto_amount_near_date"
          days = (txn.transaction_date - deposit.deposited_at.to_date).to_i.abs
          I18n.t("finance.bank_statement_transactions.match_reasons.auto_amount_near_date",
                 amount: txn.amount, days: days)
        when "auto_amount_only"
          I18n.t("finance.bank_statement_transactions.match_reasons.auto_amount_only", amount: txn.amount)
        when "auto_description_similarity"
          I18n.t("finance.bank_statement_transactions.match_reasons.auto_description_similarity")
        end
      end

      # ── Status derivation for a committed match ──────────────────────────

      # Reference number identifies the *candidate*, but never overrides the
      # actual financial comparison — a reference match with a mismatched
      # amount must still surface as amount_mismatch, not be silently
      # rubber-stamped "verified".
      def derive_status(txn, deposit)
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

      # ── Description similarity (token overlap, 0-100) ────────────────────

      def description_similarity(a, b)
        a_tokens = normalize_text(a).split(" ").to_set
        b_tokens = normalize_text(b).split(" ").to_set
        return 0 if a_tokens.empty? || b_tokens.empty?

        overlap = (a_tokens & b_tokens).size
        return 0 if overlap.zero?

        union = (a_tokens | b_tokens).size
        ((overlap.to_f / union) * 100).round
      end

      def normalize_text(value)
        value.to_s.strip.downcase.gsub(/[^\p{Alnum}\s]/, " ").gsub(/\s+/, " ").strip
      end

      # ── Loading ───────────────────────────────────────────────────────────

      # Records what each rematchable transaction's outcome was *before* this
      # run resets it, so commit_match!/mark_needs_review! can tell whether
      # the rematch actually changed anything.
      def capture_previous_outcomes!(statement)
        statement.bank_statement_transactions
                 .where(status: REMATCHABLE_STATUSES)
                 .pluck(:id, :matched_till_deposit_id, :match_method, :status)
                 .each { |id, deposit_id, method, status| @previous_outcomes[id] = [ deposit_id, method, status ] }
      end

      def reset_rematchable!(statement)
        statement.bank_statement_transactions
                 .where(status: REMATCHABLE_STATUSES)
                 .update_all(
                   matched_till_deposit_id:    nil,
                   match_method:               nil,
                   match_confidence:           nil,
                   match_reason:               nil,
                   matched_by_id:              nil,
                   matched_at:                 nil,
                   status:                     "pending",
                   snapshot_deposit_amount:    nil,
                   snapshot_deposit_date:      nil,
                   snapshot_deposit_reference: nil
                 )
      end

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

      def normalize_ref(str)
        str.to_s.strip.downcase.gsub(/\s+/, "")
      end
    end
  end
end
