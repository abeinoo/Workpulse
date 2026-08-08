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

      # PayrollPeriod has been business-wide (no branch scoping) since the
      # branch-membership refactor — `payroll_periods.branch_id` is retained
      # only for pre-refactor historical rows and is always nil on every
      # period created since (see PayrollPeriod#branch). Grouping by it (the
      # previous implementation) therefore always produced a single {nil =>
      # total} bucket, which a per-branch `payroll_costs[branch.id]` lookup
      # never matches — this is why Salary Cost always rendered as 0.
      #
      # The correct source of "which branch was this salary earned at" is the
      # same one Payroll::InsuranceExpenseGenerator already uses to attribute
      # its own payroll-derived cost (employer insurance) back to a branch:
      # ShiftAssignment.branch_ids_by_user, resolved over the period's own
      # date range (historical, not the employee's current assignment). When
      # an employee has more than one assignment in the period the
      # latest-effective one wins — no splitting/prorating, matching every
      # other consumer of this helper. Employees with no shift assignment
      # during the period fall back to the business's first branch, same as
      # InsuranceExpenseGenerator, so a real salary cost is never silently
      # dropped from the business-wide total.
      def payroll_costs
        @payroll_costs ||= begin
          rows = PayrollEntry
            .joins(:payroll_period)
            .where(payroll_periods: { business_id: @business.id, period_year: @year, period_month: @month })
            .pluck(:user_id, Arel.sql("payroll_entries.base_salary + payroll_entries.total_overtime + payroll_entries.total_bonuses"))

          branch_by_user  = ShiftAssignment.branch_ids_by_user(rows.map(&:first), from: @start, to: @end)
          # Scoped to sales branches too — falling back to a non-sales branch
          # id here would compute a real cost into this hash under a key
          # #call never reads (its own `branches` loop is sales-only), which
          # would silently drop that employee's salary from the report's
          # totals instead of attributing it to a branch that's actually shown.
          fallback_branch = @business.branches.where(branch_type: "sales").order(:id).pick(:id)

          rows.each_with_object(Hash.new(0)) do |(user_id, amount), totals|
            branch_id = branch_by_user[user_id] || fallback_branch
            totals[branch_id] += amount if branch_id
          end
        end
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

      # Standard laundry-service cost charged to each sales branch this month
      # — confirmed_quantity × the LaundryStandardCostRate effective at receipt
      # time, for towels the branch sent to be washed. Reuses
      # Laundry::BranchTowelConsumptionReport (the existing, single source of
      # this figure — also what the Laundry module's own reports display)
      # rather than recomputing it, so there is exactly one place in the
      # codebase that turns towel transfers into a cost. That report reads
      # only TowelTransfer/TowelTransferItem/LaundryStandardCostRate — none of
      # which direct_expenses/allocated_expenses/inventory_costs above ever
      # touch, so this can never double-count against them. Keyed by the same
      # branch.id the rest of #call groups by (the report itself groups by
      # transfer.source_branch_id, i.e. the sales branch that sent the
      # towels — never the laundry branch, which never appears in `branches`
      # here anyway).
      def laundry_costs
        @laundry_costs ||= Laundry::BranchTowelConsumptionReport.new(@business, from: @start, to: @end).call
          .rows.to_h { |row| [ row.branch.id, row.total_cost ] }
      end
    end
  end
end
