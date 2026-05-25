module Adjustments
  # Computes aggregate stats and insights for a given PayrollAdjustment scope.
  # Accepts the period-level scope (before additional UI filters) so stats always
  # reflect the full period regardless of what the table is filtered to.
  # A last_period_scope can optionally be passed for trend comparison.
  class SummaryData
    Result = Struct.new(
      :total_count, :bonus_total, :deduction_total,
      :employees_affected, :pending_count,
      :most_adjusted_user, :highest_bonus_adj, :highest_deduction_adj,
      :trend_delta,
      keyword_init: true
    )

    POSITIVE_SQL = PayrollAdjustment::POSITIVE_TYPES.map { |t| "'#{t}'" }.join(", ").freeze
    NEGATIVE_SQL = PayrollAdjustment::NEGATIVE_TYPES.map { |t| "'#{t}'" }.join(", ").freeze

    def initialize(period_scope, last_period_scope = nil)
      @scope      = period_scope
      @last_scope = last_period_scope
    end

    def call
      agg = aggregate_row

      Result.new(
        total_count:           agg[:total_count].to_i,
        bonus_total:           agg[:bonus_total].to_f,
        deduction_total:       agg[:deduction_total].to_f,
        employees_affected:    agg[:employees_affected].to_i,
        pending_count:         agg[:pending_count].to_i,
        most_adjusted_user:    most_adjusted_user,
        highest_bonus_adj:     highest_of(:positive),
        highest_deduction_adj: highest_of(:negative),
        trend_delta:           compute_trend(agg[:total_count].to_i)
      )
    end

    private

    def aggregate_row
      row = @scope.pick(
        Arel.sql(<<~SQL.squish)
          COUNT(*)                                                                    AS total_count,
          COUNT(DISTINCT user_id)                                                     AS employees_affected,
          SUM(CASE WHEN review_status = 'pending_review' THEN 1 ELSE 0 END)         AS pending_count,
          COALESCE(SUM(CASE WHEN adjustment_type IN (#{POSITIVE_SQL}) THEN amount ELSE 0 END), 0) AS bonus_total,
          COALESCE(SUM(CASE WHEN adjustment_type IN (#{NEGATIVE_SQL}) THEN amount ELSE 0 END), 0) AS deduction_total
        SQL
      )
      keys = %i[total_count employees_affected pending_count bonus_total deduction_total]
      keys.zip(Array(row)).to_h
    end

    def most_adjusted_user
      row = @scope
              .select("user_id, COUNT(*) AS adj_count")
              .group(:user_id)
              .order(Arel.sql("COUNT(*) DESC"))
              .limit(1)
              .first
      row&.user
    end

    def highest_of(direction)
      types = direction == :positive ? PayrollAdjustment::POSITIVE_TYPES : PayrollAdjustment::NEGATIVE_TYPES
      @scope.where(adjustment_type: types).order(amount: :desc).includes(:user).first
    end

    def compute_trend(this_count)
      return nil unless @last_scope
      last_count = @last_scope.count
      this_count - last_count
    end
  end
end
