module Finance
  module Reports
    # Monthly expense spend over a date range (committed spend by default).
    #
    # branch_id narrows it to one branch with ExpenseSummary's branch
    # attribution: the branch's own expenses plus its allocated_amount of each
    # shared expense (by the shared expense's month). Without it the trend is
    # business-wide, exactly as before.
    class ExpenseTrend
      def initialize(business, from:, to:, statuses: %w[approved], branch_id: nil)
        @business  = business
        @from      = from
        @to        = to
        @statuses  = statuses
        @branch_id = branch_id
      end

      def call
        scoped  = @business.expenses.where(status: @statuses).in_period(@from, @to)
        month   = Arel.sql("date_trunc('month', expense_date)")
        totals, counts =
          if @branch_id
            branch_totals(scoped, month)
          else
            [ scoped.group(month).sum(:amount), scoped.group(month).count ]
          end

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

      private

      def branch_totals(scoped, month)
        direct = scoped.where(branch_id: @branch_id)
        allocs = ExpenseAllocation.joins(:expense)
                                  .where(expense_id: scoped.where(is_shared: true).select(:id), branch_id: @branch_id)
                                  .group(Arel.sql("date_trunc('month', expenses.expense_date)"))
        [ direct.group(month).sum(:amount).merge(allocs.sum(:allocated_amount)) { |_k, a, b| a + b },
          direct.group(month).count.merge(allocs.count) { |_k, a, b| a + b } ]
      end
    end
  end
end
