module Finance
  module Reports
    # Shared expenses broken out into their per-branch allocated amounts — shows
    # the original expense alongside how its cost was split across branches.
    class SharedAllocation
      def initialize(business, from:, to:, statuses: %w[approved])
        @business = business
        @from     = from
        @to       = to
        @statuses = statuses
      end

      def call
        expenses = @business.expenses
                            .where(is_shared: true, status: @statuses).in_period(@from, @to)
                            .includes(:expense_category, expense_allocations: :branch)
                            .recent

        rows = expenses.flat_map do |expense|
          expense.expense_allocations.map do |alloc|
            { reference:  expense.reference_number,
              date:       I18n.l(expense.expense_date, format: :long),
              category:   expense.expense_category.name,
              branch:     alloc.branch.name,
              percentage: alloc.allocation_percentage,
              allocated:  alloc.allocated_amount }
          end
        end

        Table.new(
          title:   I18n.t("finance.reports.titles.shared_allocation"),
          columns: [
            Column.new(key: :reference,  label: I18n.t("finance.expenses.reference"), money: false),
            Column.new(key: :date,       label: I18n.t("finance.expenses.date"), money: false),
            Column.new(key: :category,   label: I18n.t("finance.expenses.category"), money: false),
            Column.new(key: :branch,     label: I18n.t("finance.expenses.branch"), money: false),
            Column.new(key: :percentage, label: I18n.t("finance.expenses.percentage"), money: false),
            Column.new(key: :allocated,  label: I18n.t("finance.expenses.allocated_amount"), money: true)
          ],
          rows:    rows,
          totals:  { allocated: rows.sum { |r| r[:allocated] } }
        )
      end
    end
  end
end
