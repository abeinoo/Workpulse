module Finance
  module Reports
    # Expense pipeline: count and total by status over a date range — shows how
    # much is in draft / pending / approved / rejected / paid.
    class ApprovalReport
      def initialize(business, from:, to:)
        @business = business
        @from     = from
        @to       = to
      end

      def call
        scoped = @business.expenses.in_period(@from, @to)
        totals = scoped.group(:status).sum(:amount)
        counts = scoped.group(:status).count

        rows = %w[draft pending_approval approved rejected].map do |status|
          { label: I18n.t("finance.expenses.statuses.#{status}"),
            count: counts[status].to_i,
            total: totals[status] || 0 }
        end

        Table.new(
          title:   I18n.t("finance.reports.titles.approvals"),
          columns: [
            Column.new(key: :label, label: I18n.t("finance.common.status"), money: false),
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
