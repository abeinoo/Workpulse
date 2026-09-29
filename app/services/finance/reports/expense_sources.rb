module Finance
  module Reports
    # Single source of truth for the five disjoint cost sources that make up
    # Branch Profitability's expense figure — extracted so Finance::Reports::
    # BranchProfitability and Finance::Reports::ExpenseDetails compute from the
    # exact same queries and can never drift apart. Coarse methods (…_costs /
    # …_expenses) are byte-for-byte what BranchProfitability used to compute
    # inline; detail methods are additive, only consumed by ExpenseDetails.
    #
    #   Payroll       : gross salary (base + overtime + bonuses) of every PayrollEntry
    #                   in the business's payroll period for the month, attributed to
    #                   the branch(es) the employee actually worked during that period —
    #                   see #payroll_costs for why this can't be read off the period
    #                   itself (PayrollPeriod is business-wide, not branch-scoped).
    #   Inventory     : cost of consumption — Inventory::ConsumptionLedger: OUT/
    #                   stock_issue movements attributed to the branch (quantity ×
    #                   unit_cost), net of voided-issue reversals; NOT purchases.
    #   Direct/Allocated expenses: approved expenses for the branch in the month, plus
    #                   the branch's allocated share of shared expenses.
    #   Laundry       : standard laundry/towel cost the branch was charged for the
    #                   month — see #laundry_costs.
    class ExpenseSources
      def initialize(business, year:, month:)
        @business = business
        @year     = year
        @month    = month
        @start    = Date.new(year, month, 1)
        @end      = @start.end_of_month
      end

      # ── Coarse, branch-summed figures (BranchProfitability's original five) ──

      def payroll_costs
        @payroll_costs ||= payroll_rows.each_with_object(Hash.new(0)) do |(user_id, amount), totals|
          branch_id = branch_by_payroll_user[user_id] || fallback_branch_id
          totals[branch_id] += amount if branch_id
        end
      end

      def inventory_costs
        @inventory_costs ||= consumption_ledger.cost_by_branch
      end

      def direct_expenses
        @direct_expenses ||= direct_expenses_scope.group(:branch_id).sum(:amount)
      end

      def allocated_expenses
        @allocated_expenses ||= allocated_expenses_scope.group(:branch_id).sum(:allocated_amount)
      end

      # Reuses Laundry::BranchTowelConsumptionReport (the existing, single source
      # of this figure — also what the Laundry module's own reports display)
      # rather than recomputing it, so there is exactly one place in the
      # codebase that turns towel transfers into a cost. Keyed by the same
      # branch.id the rest of this class groups by (the report itself groups by
      # transfer.source_branch_id, i.e. the sales branch that sent the towels —
      # never the laundry branch).
      def laundry_costs
        @laundry_costs ||= laundry_report.rows.to_h { |row| [ row.branch.id, row.total_cost ] }
      end

      # ── Detail, for ExpenseDetails' employee/product/expense-row breakdown ──

      # {branch_id => [PayrollEntry]} — same branch attribution payroll_costs
      # uses, just keyed to the full entries instead of a summed gross figure.
      def payroll_entries_by_branch
        @payroll_entries_by_branch ||= payroll_entries.includes(:user).group_by do |entry|
          branch_by_payroll_user[entry.user_id] || fallback_branch_id
        end
      end

      # {branch_id => [{product:, category:, quantity:, unit_cost:, total:}]} —
      # the same ConsumptionLedger as inventory_costs, just grouped one level
      # finer, so its sum-by-branch reconciles to inventory_costs by construction.
      # Products whose issues were fully voided in the period net to zero and
      # are left out.
      def inventory_movements_by_branch_product
        @inventory_movements_by_branch_product ||= begin
          totals   = consumption_ledger.totals_by_branch_product
          products = Product.where(id: totals.keys.map(&:second)).includes(:product_category).index_by(&:id)

          totals.each_with_object(Hash.new { |h, k| h[k] = [] }) do |((branch_id, product_id), t), grouped|
            next if t[:quantity].zero? && t[:cost].zero?

            product = products[product_id]
            grouped[branch_id] << {
              product:  product,
              category: product&.product_category&.name,
              quantity: t[:quantity],
              unit_cost: t[:quantity].to_f.zero? ? 0 : t[:cost] / t[:quantity],
              total:    t[:cost]
            }
          end
        end
      end

      # {branch_id => [Expense]} — the actual records behind direct_expenses.
      def direct_expense_records_by_branch
        @direct_expense_records_by_branch ||= direct_expenses_scope
          .includes(:expense_category, :expense_type)
          .group_by(&:branch_id)
      end

      # {branch_id => [ExpenseAllocation]} — the actual records behind allocated_expenses.
      def allocated_expense_records_by_branch
        @allocated_expense_records_by_branch ||= allocated_expenses_scope
          .includes(expense: [ :expense_category, :expense_type ])
          .group_by(&:branch_id)
      end

      # {branch_id => [Laundry::BranchTowelConsumptionReport::Event]}
      def laundry_events_by_branch
        @laundry_events_by_branch ||= laundry_report.rows.to_h { |row| [ row.branch.id, row.events ] }
      end

      private

      def payroll_rows
        @payroll_rows ||= PayrollEntry
          .joins(:payroll_period)
          .where(payroll_periods: { business_id: @business.id, period_year: @year, period_month: @month })
          .pluck(:user_id, Arel.sql("payroll_entries.base_salary + payroll_entries.total_overtime + payroll_entries.total_bonuses"))
      end

      def payroll_entries
        @payroll_entries ||= PayrollEntry
          .joins(:payroll_period)
          .where(payroll_periods: { business_id: @business.id, period_year: @year, period_month: @month })
      end

      # PayrollPeriod has been business-wide (no branch scoping) since the
      # branch-membership refactor — the correct source of "which branch was
      # this salary earned at" is the same one Payroll::InsuranceExpenseGenerator
      # already uses to attribute its own payroll-derived cost (employer
      # insurance) back to a branch: ShiftAssignment.branch_ids_by_user,
      # resolved over the period's own date range (historical, not the
      # employee's current assignment). When an employee has more than one
      # assignment in the period the latest-effective one wins — no
      # splitting/prorating, matching every other consumer of this helper.
      def branch_by_payroll_user
        @branch_by_payroll_user ||= ShiftAssignment.branch_ids_by_user(payroll_rows.map(&:first), from: @start, to: @end)
      end

      # Scoped to sales branches too — falling back to a non-sales branch id
      # here would compute a real cost into these hashes under a key
      # BranchProfitability's own sales-only branch loop never reads, which
      # would silently drop that employee's salary from the report's totals
      # instead of attributing it to a branch that's actually shown.
      def fallback_branch_id
        @fallback_branch_id ||= @business.branches.where(branch_type: "sales").order(:id).pick(:id)
      end

      def consumption_ledger
        @consumption_ledger ||= Inventory::ConsumptionLedger.new(@business, from: @start, to: @end)
      end

      def direct_expenses_scope
        @business.expenses
          .where(status: "approved").in_period(@start, @end)
          .where.not(branch_id: nil)
      end

      def allocated_expenses_scope
        shared_ids = @business.expenses.where(status: "approved", is_shared: true).in_period(@start, @end).select(:id)
        ExpenseAllocation.where(expense_id: shared_ids)
      end

      def laundry_report
        @laundry_report ||= Laundry::BranchTowelConsumptionReport.new(@business, from: @start, to: @end).call
      end
    end
  end
end
