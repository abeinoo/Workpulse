module Finance
  module Reports
    # Monthly expense spend over a date range (committed spend by default).
    class ExpenseTrend
      def initialize(business, from:, to:, statuses: %w[approved])
        @business = business
        @from     = from
        @to       = to
        @statuses = statuses
      end

      def call
        scoped  = @business.expenses.where(status: @statuses).in_period(@from, @to)
        month   = Arel.sql("date_trunc('month', expense_date)")
        totals  = scoped.group(month).sum(:amount)
        counts  = scoped.group(month).count

        rows = totals.keys.sort.map do |period|
          { label: I18n.l(period.to_date, format: "%b %Y"),
            count: counts[period].to_i,
            total: totals[period] }
        end

        Table.new(
          title:   I18n.t("finance.reports.titles.expense_trend"),
          columns: [
            Column.new(key: :label, label: I18n.t("finance.reports.month"), money: false),
            Column.new(key: :count, label: I18n.t("finance.reports.count"), money: false),
            Column.new(key: :total, label: I18n.t("finance.reports.total_amount"), money: true)
          ],
          rows:    rows,
          totals:  { count: rows.sum { |r| r[:count] }, total: rows.sum { |r| r[:total] } }
        )
      end
    end
  end
end
