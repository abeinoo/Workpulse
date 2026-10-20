module Finance
  module Reports
    # Read-only report: the central laundry's ACTUAL operating cost for a period
    # (payroll + direct expenses + material consumption), compared against the
    # STANDARD cost branches were charged (via Laundry::BranchTowelConsumptionReport).
    # These two numbers are computed completely independently and are never
    # mixed — actual cost is management analysis only, never redistributed back
    # to branches.
    #
    # Date rule per component (see class docs on each source for why):
    #   towels:    TowelTransfer#received_at
    #   expenses:  Expense#expense_date (Expense.in_period)
    #   materials: StockIssue#issued_on (the existing, authoritative Inventory
    #              Stock Issue workflow — see #laundry_material_cost_and_lines)
    #   payroll:   whole finalized/paid PayrollPeriods overlapping [from, to] —
    #              no proration; periods actually included are reported so the
    #              UI can label them explicitly.
    #
    # The report assumes exactly ONE active laundry branch. With none it returns
    # an empty result; with more than one it returns a blocked result and
    # computes nothing (picking one arbitrarily would report misleading figures).
    # Every component — standard cost, payroll, expenses, materials — is
    # restricted to that one branch.
    #
    # include_payroll: false (a viewer without view_payroll) never computes the
    # payroll cost, nor any figure derived from it (actual operating cost,
    # coverage variance, cost per towel) — those would let payroll be recovered
    # by arithmetic from the remaining components. They come back nil, with
    # payroll_included? false. payroll_branch_ids (Finance::PayrollCostAccess
    # #branch_ids) does the same when the laundry branch is outside the
    # viewer's payroll access; nil = no branch restriction.
    class LaundryCostSummary
      # One Stock Issue line item counted toward laundry material cost — carries
      # everything the report's drill-down needs (issue #, date, warehouse,
      # branch, status, product, quantity, cost) without re-deriving anything.
      MaterialLine = Struct.new(:stock_issue, :product, :quantity, :unit_cost, :total_cost, keyword_init: true)

      Result = Struct.new(
        :laundry_branch, :multiple_laundry_branches, :payroll_included,
        :consumption, :standard_towels, :standard_cost, :payroll_cost, :payroll_periods, :direct_expenses,
        :material_cost, :material_lines, :actual_operating_cost, :coverage_variance, :actual_cost_per_towel,
        keyword_init: true
      ) do
        def has_laundry_branch?         = laundry_branch.present?
        def multiple_laundry_branches?  = multiple_laundry_branches == true
        def payroll_included?           = payroll_included == true
      end

      def initialize(business, from:, to:, include_payroll: true, payroll_branch_ids: nil)
        @business        = business
        @from            = from
        @to              = to
        @include_payroll = include_payroll
        @payroll_branch_ids = payroll_branch_ids
      end

      def call
        laundry_branches = @business.branches.active.branch_type_laundry.limit(2).to_a
        return Result.new(laundry_branch: nil, multiple_laundry_branches: true) if laundry_branches.size > 1

        laundry_branch = laundry_branches.first
        return Result.new(laundry_branch: nil, payroll_included: @include_payroll) unless laundry_branch

        @include_payroll &&= @payroll_branch_ids.nil? || @payroll_branch_ids.include?(laundry_branch.id)

        consumption = Laundry::BranchTowelConsumptionReport.new(@business, from: @from, to: @to).call
        standard_towels, standard_cost = standard_coverage(consumption, laundry_branch)
        direct_expenses = laundry_direct_expenses(laundry_branch)
        material_cost, material_lines = laundry_material_cost_and_lines(laundry_branch)

        result = Result.new(
          laundry_branch:   laundry_branch,
          payroll_included: @include_payroll,
          consumption:      consumption,
          standard_towels:  standard_towels,
          standard_cost:    standard_cost,
          direct_expenses:  direct_expenses,
          material_cost:    material_cost,
          material_lines:   material_lines
        )
        return result unless @include_payroll

        payroll_cost, payroll_periods = laundry_payroll_cost(laundry_branch)
        actual = payroll_cost + direct_expenses + material_cost

        result.payroll_cost          = payroll_cost
        result.payroll_periods       = payroll_periods
        result.actual_operating_cost = actual
        result.coverage_variance     = standard_cost - actual
        result.actual_cost_per_towel = standard_towels.positive? ? (actual / standard_towels) : nil
        result
      end

      private

      # The standard cost charged for towels received at THIS laundry branch —
      # Laundry::BranchTowelConsumptionReport counts receipts at any laundry-type branch,
      # so its events are narrowed to the selected one. A receipt with no
      # configured rate contributes 0, exactly as the consumption report's rows.
      def standard_coverage(consumption, laundry_branch)
        events = consumption.rows.flat_map(&:events)
                            .select { |e| e.transfer.destination_branch_id == laundry_branch.id }

        [ events.sum(&:confirmed_quantity), events.sum { |e| e.line_total || 0 } ]
      end

      # Whole finalized/paid payroll periods overlapping [from, to]; the users
      # counted per period are whoever had a ShiftAssignment at the laundry
      # branch overlapping that period (no splitting/proration of net_salary —
      # see class docs).
      def laundry_payroll_cost(laundry_branch)
        periods = PayrollPeriod.for_business(@business)
                               .where(status: %w[finalized paid])
                               .select { |p| p.period_start <= @to.to_date && p.period_end >= @from.to_date }

        total = periods.sum do |period|
          user_ids = ShiftAssignment.user_ids_for_branch_during(laundry_branch.id,
                                                                 from: period.period_start, to: period.period_end)
          next 0 if user_ids.empty?

          PayrollEntry.where(payroll_period_id: period.id, user_id: user_ids).sum(:net_salary)
        end

        [ total, periods ]
      end

      # Mirrors Finance::Reports::ExpenseSummary#by_branch's direct+allocated
      # pattern, restricted to the laundry branch only.
      def laundry_direct_expenses(laundry_branch)
        scoped = @business.expenses.where(status: "approved").in_period(@from.to_date, @to.to_date)
        direct = scoped.where(branch_id: laundry_branch.id).sum(:amount)

        shared_ids = scoped.where(is_shared: true).select(:id)
        allocated  = ExpenseAllocation.where(expense_id: shared_ids, branch_id: laundry_branch.id)
                                      .sum(:allocated_amount)

        direct + allocated
      end

      # The existing Inventory Stock Issue workflow is the single source of
      # truth for laundry material consumption — NOT a laundry-specific
      # recording screen, and NOT a warehouse->warehouse stock transfer (a
      # transfer only relocates stock; it never posts a StockIssue). A Stock
      # Issue counts when:
      #   - it's financially effective: status "issued" (physically posted, not
      #     merely approved) and not voided (StockIssue.issued.active — voiding
      #     is the app's only "cancel" path for an issued issue; ImmutableDocument
      #     means an issued issue is never hard-deleted, so "active" is the
      #     correct exclusion, not a status check alone);
      #   - its consuming branch (StockIssue#branch) is the selected laundry branch;
      #   - its effective date (StockIssue#issued_on) falls in [from, to].
      # Cost is the existing, immutable StockIssueItem#unit_cost/#total_cost
      # snapshot — never re-derived from the product's current cost, and never
      # duplicated with any other laundry-specific cost record.
      def laundry_material_cost_and_lines(laundry_branch)
        issues = StockIssue.for_business(@business)
                           .issued.active
                           .where(branch_id: laundry_branch.id)
                           .where(issued_on: @from.to_date..@to.to_date)
                           .includes(:branch, :warehouse, items: :product)

        lines = issues.flat_map do |issue|
          issue.items.map do |item|
            MaterialLine.new(stock_issue: issue, product: item.product, quantity: item.quantity,
                             unit_cost: item.unit_cost, total_cost: item.total_cost)
          end
        end

        [ lines.sum(&:total_cost), lines ]
      end
    end
  end
end
