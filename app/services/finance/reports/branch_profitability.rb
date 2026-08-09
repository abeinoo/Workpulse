module Finance
  module Reports
    # Per-branch profit for one month:
    #
    #   Net = Revenue − Payroll − Inventory Consumption − Branch Expenses
    #
    # Revenue       : SUM(TillSessionAmount.net_amount) for verified Daily
    #                 Reconciliations in the month — see Finance::Reports::VerifiedRevenue,
    #                 the single source of truth for revenue across the Finance module.
    # Payroll       : gross salary (base + overtime + bonuses) of every PayrollEntry
    #                 in the business's payroll period for the month, attributed to
    #                 the branch(es) the employee actually worked during that period —
    #                 see #payroll_costs for why this can't be read off the period
    #                 itself (PayrollPeriod is business-wide, not branch-scoped).
    # Inventory     : cost of consumption — OUT/stock_issue movements attributed to
    #                 the branch (quantity × unit_cost), NOT purchases
    # Branch Expenses: approved+paid expenses for the branch in the month, PLUS the
    #                 branch's allocated share of shared expenses, PLUS the standard
    #                 laundry/towel cost the branch was charged for the month — see
    #                 #laundry_costs.
    #
    # All sources are computed in grouped queries keyed by branch_id, so the whole
    # report is a handful of queries regardless of branch count.
    #
    # Branch Profitability is a Sales-branch report: revenue only ever comes
    # from verified Daily Reconciliations, which only sales branches run, so
    # non-sales branches (laundry, warehouse, headquarters, maintenance,
    # other) never had meaningful profitability data to begin with — they're
    # excluded from every aggregate here rather than showing as permanent
    # all-zero rows. Same branch_type field and "sales" value Daily
    # Reconciliation's own branch scoping already uses (see
    # Finance::DailyReconciliationsController#sales_branches).
    #
    # The five cost sources themselves (payroll/inventory/direct/allocated/
    # laundry) live in Finance::Reports::ExpenseSources — the single place
    # that computes them, also consumed by Finance::Reports::ExpenseDetails
    # for its per-employee/per-product/per-expense breakdown. See that class
    # for the query-level reasoning behind each figure.
    class BranchProfitability
      def initialize(business, year:, month:)
        @business = business
        @year     = year
        @month    = month
        @start    = Date.new(year, month, 1)
        @end      = @start.end_of_month
      end

      def call
        branches = @business.branches.active.where(branch_type: "sales").order(:name)

        rows = branches.map do |branch|
          revenue   = revenues[branch.id]   || 0
          payroll   = payroll_costs[branch.id] || 0
          inventory = inventory_costs[branch.id] || 0
          expenses  = (direct_expenses[branch.id] || 0) + (allocated_expenses[branch.id] || 0) + (laundry_costs[branch.id] || 0)

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
        @revenues ||= Finance::Reports::VerifiedRevenue.new(@business, from: @start, to: @end).by_branch
      end

      def sources
        @sources ||= Finance::Reports::ExpenseSources.new(@business, year: @year, month: @month)
      end

      def payroll_costs   = sources.payroll_costs
      def inventory_costs = sources.inventory_costs
      def direct_expenses = sources.direct_expenses
      def allocated_expenses = sources.allocated_expenses
      def laundry_costs   = sources.laundry_costs
    end
  end
end
