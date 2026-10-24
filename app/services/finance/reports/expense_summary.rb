module Finance
  module Reports
    # Expense totals grouped by branch, category, or type over a date range.
    # Defaults to committed spend (approved).
    #
    # Branch grouping is special: a shared expense has no branch_id, so its cost
    # is attributed to branches through expense_allocations (allocated_amount).
    # The other groupings count each expense once under its category/type.
    #
    # branch_id (category / type grouping only) narrows those to one branch with
    # the same attribution as the branch grouping: the branch's own expenses at
    # their amount, plus its allocated_amount of each shared expense; expenses
    # with neither a branch nor allocations belong to no branch and drop out.
    # Without branch_id the report is business-wide, exactly as before.
    class ExpenseSummary
      def initialize(business, group_by:, from:, to:, statuses: %w[approved], branch_id: nil)
        @business  = business
        @group_by  = group_by.to_sym
        @from      = from
        @to        = to
        @statuses  = statuses
        @branch_id = branch_id
      end

      def call
        @group_by == :branch ? by_branch : grouped
      end

      private

      def scoped
        @business.expenses.where(status: @statuses).in_period(@from, @to)
      end

      def by_branch
        names    = @business.branches.pluck(:id, :name).to_h
        direct   = scoped.where.not(branch_id: nil)
        d_totals = direct.group(:branch_id).sum(:amount)
        d_counts = direct.group(:branch_id).count

        shared_ids = scoped.where(is_shared: true).select(:id)
        allocs     = ExpenseAllocation.where(expense_id: shared_ids).group(:branch_id)
        a_totals   = allocs.sum(:allocated_amount)
        a_counts   = allocs.count

        rows = (d_totals.keys | a_totals.keys).map do |bid|
          { label: names[bid] || "—",
            count: d_counts[bid].to_i + a_counts[bid].to_i,
            total: (d_totals[bid] || 0) + (a_totals[bid] || 0) }
        end.sort_by { |r| -r[:total] }

        build(I18n.t("finance.reports.titles.expenses_by_branch"), I18n.t("finance.expenses.branch"), rows)
      end

      def grouped
        column, resolver, title, label = group_config
        totals, counts = @branch_id ? branch_totals(column) : [ scoped.group(column).sum(:amount), scoped.group(column).count ]

        rows = totals.map { |key, total| { label: resolver.call(key), count: counts[key].to_i, total: total } }
                     .sort_by { |r| -r[:total] }
        build(title, label, rows)
      end

      # {key => total}, {key => count} for one branch: direct expenses plus the
      # branch's allocations of shared expenses (one allocation per expense and
      # branch — unique index — so a shared expense counts once). Allocations are
      # grouped by the EXPENSE's column (an Arel attribute — qualified, no SQL
      # string interpolation).
      def branch_totals(column)
        direct   = scoped.where(branch_id: @branch_id)
        allocs   = ExpenseAllocation.joins(:expense)
                                    .where(expense_id: scoped.where(is_shared: true).select(:id), branch_id: @branch_id)
                                    .group(Expense.arel_table[column])
        totals   = direct.group(column).sum(:amount).merge(allocs.sum(:allocated_amount)) { |_k, a, b| a + b }
        counts   = direct.group(column).count.merge(allocs.count) { |_k, a, b| a + b }
        [ totals, counts ]
      end

      def group_config
        case @group_by
        when :category
          names = @business.expense_categories.pluck(:id, :name).to_h
          [ :expense_category_id, ->(k) { names[k] || "—" },
            I18n.t("finance.reports.titles.expenses_by_category"), I18n.t("finance.expenses.category") ]
        when :type
          names = @business.expense_types.pluck(:id, :name).to_h
          [ :expense_type_id, ->(k) { k ? names[k] : I18n.t("finance.reports.untyped") },
            I18n.t("finance.reports.titles.expenses_by_type"), I18n.t("finance.expenses.type") ]
        else
          raise ArgumentError, "unknown group_by #{@group_by}"
        end
      end

      def build(title, group_label, rows)
        Table.new(
          title:   title,
          columns: [
            Column.new(key: :label, label: group_label, money: false),
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
