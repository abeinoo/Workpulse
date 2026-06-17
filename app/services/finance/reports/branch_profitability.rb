module Finance
  module Reports
    # Per-branch profit for one month:
    #
    #   Net = Revenue − Payroll − Inventory Consumption − Branch Expenses
    #
    # Revenue       : manual branch_revenues for the month
    # Payroll       : gross salary (base + overtime + bonuses) of the branch's
    #                 payroll period for the month
    # Inventory     : cost of consumption — OUT/stock_issue movements attributed to
    #                 the branch (quantity × unit_cost), NOT purchases
    # Branch Expenses: approved+paid expenses for the branch in the month, PLUS the
    #                 branch's allocated share of shared expenses
    #
    # All sources are computed in grouped queries keyed by branch_id, so the whole
    # report is a handful of queries regardless of branch count.
    class BranchProfitability
      def initialize(business, year:, month:)
        @business = business
        @year     = year
        @month    = month
        @start    = Date.new(year, month, 1)
        @end      = @start.end_of_month
      end

      def call
        branches = @business.branches.active.order(:name)

        rows = branches.map do |branch|
          revenue   = revenues[branch.id]   || 0
          payroll   = payroll_costs[branch.id] || 0
          inventory = inventory_costs[branch.id] || 0
          expenses  = (direct_expenses[branch.id] || 0) + (allocated_expenses[branch.id] || 0)

          { branch:    branch.name,
            revenue:   revenue,
            payroll:   payroll,
            inventory: inventory,
            expenses:  expenses,
            net:       revenue - payroll - inventory - expenses }
        end

        Table.new(
          title:   I18n.t("finance.reports.titles.branch_profitability"),
          columns: [
            Column.new(key: :branch,    label: I18n.t("finance.expenses.branch"), money: false),
            Column.new(key: :revenue,   label: I18n.t("finance.reports.revenue"), money: true),
            Column.new(key: :payroll,   label: I18n.t("finance.reports.payroll_cost"), money: true),
            Column.new(key: :inventory, label: I18n.t("finance.reports.inventory_cost"), money: true),
            Column.new(key: :expenses,  label: I18n.t("finance.reports.branch_expenses"), money: true),
            Column.new(key: :net,       label: I18n.t("finance.reports.net_profit"), money: true)
          ],
          rows:    rows,
          totals:  %i[revenue payroll inventory expenses net].index_with { |k| rows.sum { |r| r[k] } }
        )
      end

      private

      def revenues
        @revenues ||= @business.branch_revenues.where(period_month: @start).group(:branch_id).sum(:amount)
      end

      def payroll_costs
        @payroll_costs ||= PayrollEntry
          .joins(:payroll_period)
          .where(payroll_periods: { business_id: @business.id, period_year: @year, period_month: @month })
          .group("payroll_periods.branch_id")
          .sum("payroll_entries.base_salary + payroll_entries.total_overtime + payroll_entries.total_bonuses")
      end

      def inventory_costs
        @inventory_costs ||= InventoryMovement.consumption
          .where(business_id: @business.id)
          .occurred_between(@start, @end)
          .group(:branch_id)
          .sum(Arel.sql("quantity * unit_cost"))
      end

      def direct_expenses
        @direct_expenses ||= @business.expenses
          .where(status: "approved").in_period(@start, @end)
          .where.not(branch_id: nil).group(:branch_id).sum(:amount)
      end

      def allocated_expenses
        shared_ids = @business.expenses.where(status: "approved", is_shared: true).in_period(@start, @end).select(:id)
        @allocated_expenses ||= ExpenseAllocation.where(expense_id: shared_ids).group(:branch_id).sum(:allocated_amount)
      end
    end
  end
end
