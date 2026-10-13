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
        @pending_sales  = @sales.sort_by(&:id)
        @pool_pos       = @pos.sort_by(&:id)
        @matched        = []
        @consumed_sales = Set.new
        @consumed_pos   = Set.new

        run_reference_tier!
        drop_consumed!
        run_amount_date_time_window_tier!
        drop_consumed!

        Result.new(matched_pairs: @matched, missing_from_pos: @pending_sales, extra_in_pos: @pool_pos)
      end

      private

      # POS rows are grouped by normalized reference once, up front (pool
      # order, i.e. ascending id, is kept within each group). Equivalent to
      # re-selecting from the live pool per bucket: a POS row can only be
      # consumed by the bucket of its own reference, and each reference is
      # visited once, so a group never contains a row consumed earlier.
      def run_reference_tier!
        buckets = {}
        @pending_sales.each do |s|
          ref = normalize_ref(s.reference_number)
          next if ref.blank?
          (buckets[ref] ||= []) << s
        end
        return if buckets.empty?

        pos_by_ref = @pool_pos.group_by { |p| normalize_ref(p.reference_number) }

        buckets.each do |ref, sales_group|
          pos_group = pos_by_ref[ref]
          next if pos_group.nil?

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
      #
      # The remaining pool is grouped once by (amount, calendar date) — the
      # two equality conditions every candidate must meet — keeping ascending
      # id order within each group, so each Sales Transaction scans only its
      # own amount/date candidates instead of the whole pool. A claimed row is
      # removed from its group. The scan keeps the FIRST row (in id order)
      # with the smallest time difference — exactly what select + min_by did.
      def run_amount_date_time_window_tier!
        buckets = {}
        @pending_sales.each { |s| (buckets[s.amount] ||= []) << s }
        return if buckets.empty?

        candidates = @pool_pos.group_by { |p| [ amount_key(p.amount), p.transaction_date&.to_date ] }

        buckets.each do |amount, sales_group|
          key = amount_key(amount)

          sales_group.sort_by(&:id).each do |s|
            sales_timestamp = combined_timestamp(s)
            next if sales_timestamp.nil?

            pool = candidates[[ key, s.transaction_date ]]
            next if pool.nil?

            candidate = nil
            best_gap  = nil
            pool.each do |p|
              gap = (p.transaction_date - sales_timestamp).abs
              next if gap > TIME_WINDOW

              if best_gap.nil? || gap < best_gap
                candidate = p
                best_gap  = gap
              end
            end

            next unless candidate

            commit_match!(s, candidate, :amount_date_time_window)
            pool.delete(candidate)
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

      # Consumption is recorded in sets and applied to @pending_sales/@pool_pos
      # by drop_consumed! between tiers — nothing reads those arrays mid-tier
      # (each tier works from its own groups), and Set membership uses the
      # records' own eql?/hash (ActiveRecord: same class + id), so the result
      # is exactly what deleting every equal element on each match produced,
      # without an O(n) Array#delete per match.
      def commit_match!(sales_transaction, pos_transaction, method)
        @matched << MatchedPair.new(sales_transaction: sales_transaction, pos_transaction: pos_transaction, method: method)
        @consumed_sales << sales_transaction
        @consumed_pos << pos_transaction
      end

      def drop_consumed!
        @pending_sales.reject! { |s| @consumed_sales.include?(s) } if @consumed_sales.any?
        @pool_pos.reject! { |p| @consumed_pos.include?(p) } if @consumed_pos.any?
      end

      def normalize_ref(str)
        str.to_s.strip.downcase.gsub(/\s+/, "")
      end

      # Hash key standing in for the tier's `p.amount == amount` test.
      # BigDecimal hashes by value regardless of scale (POS amounts are
      # scale 2, Sales scale 4), so equal amounts share a key — except
      # 0 vs -0, which are == but hash differently, so zero is normalized.
      def amount_key(amount)
        amount.respond_to?(:zero?) && amount.zero? ? 0 : amount
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
