module Finance
  module Reports
    # The single source of truth for "revenue" anywhere in the Finance module.
    #
    # Revenue = SUM(TillSessionAmount.net_amount) — collected_amount minus
    # refund_amount, the DR's own "official per-payment-method totals
    # snapshot, written at day close" — for DailyReconciliation records that
    # are verified (accounting-approved; verified_at present). Unverified,
    # closed-but-not-yet-verified, or open reconciliations never count.
    #
    # SalesTransaction (imported POS data) is verification data only and must
    # never be read here — do not add it as a second revenue path.
    #
    # business_date is already business-day-adjusted (stamped from
    # BusinessDay.current at DR creation), so it's safe to filter directly
    # against a plain Date range without further rollover handling.
    class VerifiedRevenue
      def initialize(business, from:, to:, branch_ids: nil)
        @business   = business
        @from       = from
        @to         = to
        @branch_ids = branch_ids
      end

      def total
        scope.sum(net_amount_sql)
      end

      def by_branch
        scope.group(:branch_id).sum(net_amount_sql)
      end

      # Keys normalized to Date — Postgres/Rails returns date_trunc() grouping
      # keys as Time, which never #eql? a Date even for the same calendar day
      # (Hash#[] uses eql?, not ==), so any caller probing this hash with a
      # plain Date (e.g. months.map { |m| by_month[m] }) would silently get
      # nil for every key without this normalization.
      def by_month
        scope.group(Arel.sql("date_trunc('month', business_date)")).sum(net_amount_sql)
             .transform_keys(&:to_date)
      end

      # Whether any verified Daily Reconciliation exists for this scope at
      # all — the correct "is there data" check for empty-state rendering.
      # Distinct from total.zero?, which can't tell "no data" apart from "a
      # verified DR that happened to net to exactly 0."
      def any?
        scope.exists?
      end

      private

      def scope
        relation = DailyReconciliation.for_business(@business).verified.in_period(@from, @to).joins(:session_amounts)
        @branch_ids ? relation.where(branch_id: @branch_ids) : relation
      end

      def net_amount_sql
        Arel.sql("till_session_amounts.collected_amount - till_session_amounts.refund_amount")
      end
    end
  end
end
