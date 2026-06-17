module Finance
  module Reports
    # All recurring templates with their monthly-equivalent run-rate, so the
    # business can see committed recurring spend at a glance.
    MONTHLY_FACTOR = { "weekly" => (52.0 / 12), "monthly" => 1, "quarterly" => (1.0 / 3), "yearly" => (1.0 / 12) }.freeze

    class RecurringSummary
      def initialize(business)
        @business = business
      end

      def call
        recs = @business.recurring_expenses.includes(:expense_category, :branch, :recurring_expense_allocations).ordered

        rows = recs.map do |rec|
          { category:  rec.expense_category.name,
            frequency: I18n.t("finance.recurring.frequencies.#{rec.frequency}"),
            branch:    rec.recurring_expense_allocations.any? ? I18n.t("finance.expenses.shared") : (rec.branch&.name || "—"),
            amount:    rec.amount,
            monthly:   (rec.amount * MONTHLY_FACTOR.fetch(rec.frequency, 1)).round(2),
            next_run:  I18n.l(rec.next_run_on, format: :long),
            status:    rec.active? ? I18n.t("finance.common.active") : I18n.t("finance.common.inactive") }
        end

        Table.new(
          title:   I18n.t("finance.reports.titles.recurring"),
          columns: [
            Column.new(key: :category,  label: I18n.t("finance.expenses.category"), money: false),
            Column.new(key: :frequency, label: I18n.t("finance.recurring.frequency"), money: false),
            Column.new(key: :branch,    label: I18n.t("finance.expenses.branch"), money: false),
            Column.new(key: :amount,    label: I18n.t("finance.expenses.amount"), money: true),
            Column.new(key: :monthly,   label: I18n.t("finance.reports.monthly_equivalent"), money: true),
            Column.new(key: :next_run,  label: I18n.t("finance.recurring.next_run_on"), money: false),
            Column.new(key: :status,    label: I18n.t("finance.common.status"), money: false)
          ],
          rows:    rows,
          totals:  { monthly: rows.select { |r| r[:status] == I18n.t("finance.common.active") }.sum { |r| r[:monthly] } }
        )
      end
    end
  end
end
