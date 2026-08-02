module Payroll
  # Called once, inside Payroll::Approver's "finalized" transition — the payroll
  # approval point of no return. Sums the employer share across the period's
  # insured entries and, if positive, creates one system-generated Expense for
  # it — never touches net salary, purely a P&L record (Social Insurance
  # Expense). The employee share is already applied as a payroll deduction by
  # Payroll::EntryCalculator; nothing further happens to it here.
  #
  # No liability or settlement record is created — the Expense itself, via the
  # existing Expense approval/void workflow, is the entire feature. Idempotent:
  # a period can have at most one active (non-voided) system-generated
  # insurance Expense, enforced by a partial unique index on
  # expenses.source_payroll_period_id.
  class InsuranceExpenseGenerator
    include AuditLoggable

    EXPENSE_CATEGORY_NAME = "Social Insurance".freeze

    Result = Struct.new(:ok, :expense, :error, keyword_init: true) { def ok? = ok }

    def self.call(period:, actor:)
      new(period: period, actor: actor).call
    end

    def initialize(period:, actor:)
      @period = period
      @actor  = actor
    end

    def call
      return Result.new(ok: true) if Expense.where(source_payroll_period: @period, voided_at: nil).exists?

      insured_entries = @period.payroll_entries.where(insured: true)
      employer_total   = insured_entries.sum(:employer_insurance_amount)

      return Result.new(ok: true) if employer_total <= 0

      expense = build_employer_expense(@period.business, insured_entries, employer_total)

      Result.new(ok: true, expense: expense)
    end

    private

    # Expense requires either a specific branch_id, or (when branch-less) a
    # full percentage/amount split across branches via expense_allocations —
    # there's no "unscoped, no split" option (see Expense#normalize_branch_mode).
    # Payroll itself is business-wide (no branch scoping), so we derive branch
    # attribution from where the insured employees actually worked during the
    # period, splitting the employer contribution proportionally when they
    # span more than one branch. This mirrors Finance::RecurringExpenseGenerator's
    # use of AllocationCalculator for shared templates.
    def build_employer_expense(business, insured_entries, employer_total)
      category = business.expense_categories.find_or_create_by!(name: EXPENSE_CATEGORY_NAME) do |c|
        c.active = true
      end

      branch_totals = employer_total_by_branch(insured_entries)

      expense = business.expenses.build(
        expense_category:      category,
        deduct_from_balance:   false,
        amount:                employer_total,
        expense_date:          @period.period_end,
        status:                "approved",
        approved_at:           Time.current,
        approved_by:           @actor,
        created_by:            @actor,
        source_payroll_period: @period
      )

      if branch_totals.size == 1
        expense.branch_id = branch_totals.keys.first
      else
        expense.distribution_method = "percentage"
        build_manual_allocations(expense, branch_totals, employer_total)
      end

      expense.reference_number = Finance::NumberSequencer.new(business, :expense).next_number
      expense.save!

      log_audit(actor: @actor, auditable: expense, action: "insurance_expense_generated",
                metadata: { payroll_period_id: @period.id, employer_total: employer_total.to_s })
      expense
    end

    # Builds allocations with amounts taken directly from branch_totals (already
    # exact — no re-derivation), and percentages that sum to exactly 100 by
    # absorbing rounding into the last row (mirrors AllocationCalculator's own
    # #distribute_amounts residual technique). Deliberately doesn't go through
    # AllocationCalculator's :manual mode, whose independently-rounded
    # percentages-from-amounts can sum to 99.99/100.01 for 3+ branches and trip
    # Expense's allocation_not_100 validation.
    def build_manual_allocations(expense, branch_totals, employer_total)
      running_pct = 0.to_d
      branch_totals.keys.each_with_index do |branch_id, i|
        amount = branch_totals[branch_id]
        pct = if i == branch_totals.size - 1
          100 - running_pct
        else
          (amount.to_d / employer_total.to_d * 100).round(2)
        end
        running_pct += pct
        expense.expense_allocations.build(branch_id: branch_id, allocated_amount: amount, allocation_percentage: pct)
      end
    end

    # {branch_id => employer_contribution_sum} for the insured entries, keyed by
    # each employee's branch during the period (latest-effective assignment
    # wins — see ShiftAssignment.branch_ids_by_user). Employees with no shift
    # assignment during the period (or if the business has no branches at all)
    # fall back to the business's first branch so attribution never blocks
    # expense creation — this is cost bookkeeping, not a physical-location claim.
    def employer_total_by_branch(insured_entries)
      rows = insured_entries.pluck(:user_id, :employer_insurance_amount)
      branch_by_user = ShiftAssignment.branch_ids_by_user(
        rows.map(&:first), from: @period.period_start, to: @period.period_end
      )
      fallback_branch_id = @period.business.branches.order(:id).pick(:id)

      rows.each_with_object(Hash.new(0)) do |(user_id, amount), totals|
        branch_id = branch_by_user[user_id] || fallback_branch_id
        totals[branch_id] += amount if branch_id
      end
    end
  end
end
