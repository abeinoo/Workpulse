module Finance
  module PosVerification
    # Read-only, in-memory comparison between the electronic Sales
    # Transactions recorded against a DailyReconciliation (SalesTransaction,
    # imported from the provider's sales export and matched to the DR by
    # Finance::SalesImports::DrMatcher) and the POS Transactions imported for
    # the same branch/business day (PosTransaction, imported from the
    # provider's payment-terminal export). Nothing is persisted — this exists
    # purely to power the DR show page's "POS Transaction Verification"
    # section.
    #
    # Borrows the pooled/FIFO-consuming matching approach from
    # Finance::DepositVerification::MatchingEngine (see that file for the
    # full rationale behind deterministic FIFO pairing within a bucket)
    # rather than that engine's DB-backed match persistence — there is no
    # equivalent of DepositMatch here, and nothing about a comparison run is
    # ever written back to either transaction.
    #
    # Matching priority (highest first) — a Sales Transaction is claimed by
    # the first tier that finds it an eligible, still-unclaimed POS
    # Transaction:
    #   1. Reference Number (normalized, both sides non-blank). A pair found
    #      this way can still have a different amount on each side — that is
    #      surfaced via MatchedPair#amount_mismatch?, never hidden.
    #   2. Amount + Date + Time Window (TIME_WINDOW, a configurable constant
    #      — default 10 minutes): the closest-in-time candidate (by absolute
    #      difference between the two timestamps) is claimed first, to
    #      tolerate clock drift between the two systems. A Sales Transaction
    #      with no recorded transaction_time cannot be matched at this tier
    #      and is left unmatched.
    #
    # There used to be a separate, time-agnostic "Amount + Date" tier between
    # these two. It was removed: with Payment Method no longer a matching
    # condition (see below), that tier's candidate set was always a superset
    # of Tier 2's, so it would claim every same-amount/same-date pair via
    # FIFO before Tier 2 ever ran — making the time-window tier permanently
    # unreachable. Merging them into one Amount+Date+Time-Window tier is what
    # actually lets the ±10-minute rule take effect.
    #
    # Payment Method is deliberately NOT a matching condition at any tier —
    # the POS provider exports every card transaction under one generic
    # channel ("Card"), while Sales Transactions record the specific card
    # scheme (Visa, Mastercard, Meeza, ...); comparing them produced false
    # mismatches and blocked otherwise-legitimate matches. Payment Method
    # remains available for display only.
    #
    # Anything left unclaimed after both tiers is reported as
    # missing_from_pos (Sales side) or extra_in_pos (POS side) — never
    # silently dropped.
    class Comparator
      # Configurable — widen/narrow the Tier 2 tolerance without touching
      # the matching algorithm itself.
      TIME_WINDOW = 10.minutes

      MatchedPair = Struct.new(:sales_transaction, :pos_transaction, :method, keyword_init: true) do
        def amount_mismatch? = sales_transaction.amount != pos_transaction.amount
      end

      Result = Struct.new(:matched_pairs, :missing_from_pos, :extra_in_pos, keyword_init: true) do
        def sales_total   = matched_pairs.sum { |p| p.sales_transaction.amount } + missing_from_pos.sum(&:amount)
        def pos_total     = matched_pairs.sum { |p| p.pos_transaction.amount } + extra_in_pos.sum(&:amount)
        def difference    = sales_total - pos_total
        def sales_count   = matched_pairs.size + missing_from_pos.size
        def pos_count     = matched_pairs.size + extra_in_pos.size
        def matched_count = matched_pairs.size

        def balanced?
          missing_from_pos.empty? && extra_in_pos.empty? &&
            matched_pairs.none?(&:amount_mismatch?) && difference.abs < 0.01
        end
      end

      def self.call(sales_transactions, pos_transactions)
        new(sales_transactions, pos_transactions).call
      end

      def initialize(sales_transactions, pos_transactions)
        @sales = sales_transactions.to_a
        @pos   = pos_transactions.to_a
      end

      def call
        @pending_sales = @sales.sort_by(&:id)
        @pool_pos      = @pos.sort_by(&:id)
        @matched       = []

        run_reference_tier!
        run_amount_date_time_window_tier!

        Result.new(matched_pairs: @matched, missing_from_pos: @pending_sales, extra_in_pos: @pool_pos)
      end

      private

      def run_reference_tier!
        buckets = {}
        @pending_sales.each do |s|
          ref = normalize_ref(s.reference_number)
          next if ref.blank?
          (buckets[ref] ||= []) << s
        end

        buckets.each do |ref, sales_group|
          pos_group = @pool_pos.select { |p| normalize_ref(p.reference_number) == ref }
          next if pos_group.empty?

          resolve_bucket!(sales_group, pos_group, :reference_number)
        end
      end

      # Greedy nearest-time claim, processed one Sales Transaction at a time
      # (ascending id) rather than bucket-then-FIFO — the tier's whole point
      # is tolerating clock drift between the two systems, so the closest
      # available POS Transaction in time (by absolute difference, within
      # TIME_WINDOW) is the right partner, not simply the Nth by id. Once a
      # pair is committed, both records are consumed (see commit_match!) and
      # can never be matched again.
      def run_amount_date_time_window_tier!
        buckets = {}
        @pending_sales.each { |s| (buckets[s.amount] ||= []) << s }

        buckets.each do |amount, sales_group|
          next if @pool_pos.none? { |p| p.amount == amount }

          sales_group.sort_by(&:id).each do |s|
            sales_timestamp = combined_timestamp(s)
            next if sales_timestamp.nil?

            candidate = @pool_pos
              .select { |p| p.amount == amount && p.transaction_date.to_date == s.transaction_date &&
                            (p.transaction_date - sales_timestamp).abs <= TIME_WINDOW }
              .min_by { |p| (p.transaction_date - sales_timestamp).abs }

            commit_match!(s, candidate, :amount_date_time_window) if candidate
          end
        end
      end

      # The Nth sales row (sorted by id) claims the Nth pos row (sorted by
      # id) — deterministic FIFO, identical in spirit to MatchingEngine's
      # resolve_bucket!, so "three 100s vs three 100s" resolves as three
      # clean matches instead of refusing on ambiguity.
      def resolve_bucket!(sales_group, pos_group, method)
        sales_group = sales_group.sort_by(&:id)
        pos_group   = pos_group.sort_by(&:id)

        sales_group.zip(pos_group).each do |s, p|
          break if p.nil?
          commit_match!(s, p, method)
        end
      end

      def commit_match!(sales_transaction, pos_transaction, method)
        @matched << MatchedPair.new(sales_transaction: sales_transaction, pos_transaction: pos_transaction, method: method)
        @pending_sales.delete(sales_transaction)
        @pool_pos.delete(pos_transaction)
      end

      def normalize_ref(str)
        str.to_s.strip.downcase.gsub(/\s+/, "")
      end

      def combined_timestamp(sales_transaction)
        return nil if sales_transaction.transaction_date.nil? || sales_transaction.transaction_time.nil?

        date = sales_transaction.transaction_date
        time = sales_transaction.transaction_time
        Time.zone.local(date.year, date.month, date.day, time.hour, time.min, time.sec)
      end
    end
  end
end
