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
    # Matching runs in two priority tiers (SCORE_* constants below): reference
    # number, then exact amount+date. Within each tier, remaining transactions
    # are grouped into buckets that share the tier's matching key, together
    # with the pool deposits eligible for that bucket. Each bucket is then
    # resolved by **FIFO pairing**: transactions sorted by id, deposits sorted
    # by created_at (ties broken by id) — the Nth transaction claims the Nth
    # deposit. This single rule covers every shape:
    #
    #   txns.size == deposits.size  → every transaction gets exactly one
    #                                  deposit. This is what makes
    #                                  "300/300/300 vs 300/300/300" resolve as
    #                                  3 clean matches instead of 3 refusals.
    #
    #   txns.size >  deposits.size  → deposit deficit. Every available deposit
    #                                  is claimed by the earliest (lowest id)
    #                                  transactions; the excess transactions
    #                                  have no candidate left and fall through
    #                                  to the next tier (or to "no match" if
    #                                  none remains). This is "300,300 vs 300 →
    #                                  1 matched, 1 unmatched".
    #
    #   txns.size <  deposits.size  → deposit surplus. When several equally-
    #                                  eligible deposits share the same
    #                                  amount + date, the *oldest* unmatched
    #                                  deposit (earliest created_at — first
    #                                  recorded, first reconciled) is
    #                                  auto-matched; the newer ones are left
    #                                  untouched in the pool as candidates for
    #                                  the manual-match modal. No guessing by
    #                                  description similarity — FIFO is
    #                                  deterministic and always resolvable.
    #
    # Transactions with no candidate at any tier are classified "unexpected"
    # (or a mismatch hint) exactly as before.
    #
    # A candidate can clear a tier's bucketing key (reference number) without
    # actually satisfying amount+date equality — commit_match! re-checks that
    # independently and refuses to auto-link anything short of it, surfacing
    # a "date_mismatch"/"amount_mismatch" instead. There is no day-tolerance
    # auto-match tier: deposit date is the source of truth (calendar date
    # only — deposited_at.to_date / transaction_date are date columns, so
    # time-of-day never enters any comparison in this engine), and a
    # same-amount/different-date pair is always left unmatched for the
    # accountant's explicit Manual Match action, never silently linked.
    #
    # Branch scoping is enforced by #load_deposits (only deposits from the
    # statement's branch, when the statement is branch-scoped, ever enter the
    # pool). Payment method is not a matching dimension: every bank statement
    # transaction in this system represents a cash till deposit reaching the
    # bank, so the payment method side of the "same branch, same payment
    # method, same amount, same date" rule is a constant (cash-only) and
    # never distinguishes candidates.
    class MatchingEngine
      include AuditLoggable

      REMATCHABLE_STATUSES = %w[
        pending unexpected amount_mismatch date_mismatch needs_reverification needs_manual_review
      ].freeze

      # A deposit can only ever be AUTO-matched to a transaction when both the
      # amount and the date agree exactly (deposit date is the source of
      # truth — see #derive_status). There is deliberately no day-tolerance
      # tier: a same-amount, different-date pair is always surfaced as
      # "date_mismatch" and left unmatched, never silently auto-linked — an
      # accountant who believes it's a genuine banking delay must use the
      # explicit Manual Match action instead (see commit_match!'s gate).
      SCORE_REFERENCE   = 100
      SCORE_AMOUNT_DATE = 90

      METHOD_FOR_SCORE = {
        SCORE_REFERENCE   => "auto_reference",
        SCORE_AMOUNT_DATE => "auto_amount_date"
      }.freeze

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

          # Anything still pending after every tier had no usable candidate.
          @pending.each do |txn|
            classify_no_match!(txn, all_deposit_amounts, all_deposit_dates)
          end

          # Recompute counters from the database rather than tallying in
          # memory, so they reflect the true state of every transaction
          # (including rows untouched by this run, e.g. already verified).
          txn_scope = statement.bank_statement_transactions
          matched      = txn_scope.where.associated(:deposit_matches).count
          needs_review = txn_scope.where(status: "needs_manual_review").count
          unmatched    = txn_scope.where.missing(:deposit_matches)
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

      # ── Bucket resolution: deterministic FIFO pairing ───────────────────

      # The Nth transaction (sorted by id) claims the Nth deposit (sorted by
      # created_at — earliest recorded first, ties broken by id). When there
      # are more deposits than transactions, the newest deposits are simply
      # never reached and stay in the pool for manual matching. When there
      # are more transactions than deposits, the excess transactions get no
      # partner here and fall through to the next tier / final classification.
      def resolve_bucket!(txns, deposits, score)
        txns     = txns.sort_by(&:id)
        deposits = deposits.sort_by { |d| [ d.created_at, d.id ] }

        txns.zip(deposits).each do |txn, dep|
          break if dep.nil?
          commit_match!(txn, dep, score)
        end
      end

      # ── Committing outcomes ──────────────────────────────────────────────

      def commit_match!(txn, deposit, score)
        status = derive_status(txn, deposit)

        # Hard gate: a TillDeposit can only be AUTOMATICALLY matched to a
        # transaction when amount AND date both agree. A candidate that
        # cleared a tier on some other signal (reference number) but doesn't
        # actually satisfy that — most notably a same-amount, different-date
        # pair — is never auto-linked; it's surfaced as a mismatch and left
        # for the accountant's explicit Manual Match action instead. The
        # deposit stays in the pool so a later, better-suited pairing can
        # still claim it.
        return decline_match!(txn, status) unless status == "verified"

        method = METHOD_FOR_SCORE.fetch(score)
        reason = match_reason(method, txn)

        DepositMatch.create_for!(till_deposit: deposit, bank_statement_transaction: txn)

        txn.update!(
          match_method:     method,
          match_confidence: score,
          match_reason:     reason,
          status:           status
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

      # A candidate cleared a tier's bucketing key (reference number) but
      # fails the hard amount+date gate. No DepositMatch is created and the
      # deposit is left untouched in the pool — only the transaction is
      # classified and removed from @pending, matching the same "no audit
      # entry for an automatic non-match" that classify_no_match! already
      # uses elsewhere in this engine.
      def decline_match!(txn, status)
        txn.update!(status: status, match_method: nil, match_confidence: nil, match_reason: nil)
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

      def match_reason(method, txn)
        case method
        when "auto_reference"
          I18n.t("finance.bank_statement_transactions.match_reasons.auto_reference",
                 reference: txn.reference_number)
        when "auto_amount_date"
          I18n.t("finance.bank_statement_transactions.match_reasons.auto_amount_date",
                 amount: txn.amount, date: I18n.l(txn.transaction_date))
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

      # ── Loading ───────────────────────────────────────────────────────────

      # Records what each rematchable transaction's outcome was *before* this
      # run resets it, so commit_match!/decline_match! can tell whether the
      # rematch actually changed anything.
      def capture_previous_outcomes!(statement)
        rematchable_ids = statement.bank_statement_transactions
                                    .where(status: REMATCHABLE_STATUSES)
                                    .pluck(:id)
        return if rematchable_ids.empty?

        deposit_id_by_txn = DepositMatch.where(bank_statement_transaction_id: rematchable_ids)
                                         .pluck(:bank_statement_transaction_id, :till_deposit_id)
                                         .to_h

        statement.bank_statement_transactions
                 .where(id: rematchable_ids)
                 .pluck(:id, :match_method, :status)
                 .each { |id, method, status| @previous_outcomes[id] = [ deposit_id_by_txn[id], method, status ] }
      end

      def reset_rematchable!(statement)
        rematchable_ids = statement.bank_statement_transactions
                                    .where(status: REMATCHABLE_STATUSES)
                                    .pluck(:id)
        return if rematchable_ids.empty?

        DepositMatch.where(bank_statement_transaction_id: rematchable_ids).delete_all

        statement.bank_statement_transactions
                 .where(id: rematchable_ids)
                 .update_all(
                   match_method:     nil,
                   match_confidence: nil,
                   match_reason:     nil,
                   status:           "pending"
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
          .where.missing(:deposit_matches)

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
