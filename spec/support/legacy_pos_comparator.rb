# Frozen, verbatim copy of Finance::PosVerification::Comparator's matching
# algorithm as of commit 42a7db9 (before the index performance pass) — the
# reference implementation the equivalence specs compare the optimized
# Comparator against. Test-only: never load this from app code, and never
# "fix" it — its whole value is that it does not change.
module LegacyPosComparator
  class Comparator
    TIME_WINDOW = Finance::PosVerification::Comparator::TIME_WINDOW
    MatchedPair = Finance::PosVerification::Comparator::MatchedPair
    Result      = Finance::PosVerification::Comparator::Result

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
