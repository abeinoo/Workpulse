module Finance
  # The Social Insurance Expense that records a finalized payroll period's
  # employer insurance cost, and its void when the period is reopened (FS-D1).
  # Reached only through Payroll::FinalizationEffects (implemented by
  # Finance::PayrollFinalizationEffects); Payroll supplies the cost as data
  # (total + {branch_id => amount}), so this service reads no payroll entries
  # or shift assignments.
  #
  # Purely a P&L record — never touches net salary; the employee share is
  # applied as a payroll deduction by Payroll::EntryCalculator. No liability
  # or settlement record is created. Idempotent: a period has at most one
  # active (non-voided) insurance Expense, enforced by a partial unique index
  # on expenses.source_payroll_period_id.
  #
  # Moved unchanged from Payroll::InsuranceExpenseGenerator (Milestone 2 —
  # Finance & Sales Expenses, M4).
  class PayrollInsuranceExpense
    include AuditLoggable

    EXPENSE_CATEGORY_NAME = "Social Insurance".freeze

    Result = Struct.new(:ok, :expense, :error, keyword_init: true) { def ok? = ok }

    def self.record(period:, actor:, total:, by_branch:)
      new(period: period, actor: actor).record(total: total, by_branch: by_branch)
    end

    # The active insurance Expense no longer reflects the payroll once the
    # period is reopened, so it is voided — kept as history, never edited or
    # deleted — and the next finalization records a fresh one. Status becomes
    # "cancelled" as well, because Finance reports count expenses by status,
    # not by voided_at.
    def self.void_for(period:, actor:, reason:)
      new(period: period, actor: actor).void_active!(reason: reason)
    end

    def initialize(period:, actor:)
      @period = period
      @actor  = actor
    end

    def record(total:, by_branch:)
      return Result.new(ok: true) if Expense.where(source_payroll_period: @period, voided_at: nil).exists?
      return Result.new(ok: true) if total <= 0

      expense = build_employer_expense(@period.business, total, by_branch)

      Result.new(ok: true, expense: expense)
    end

    def void_active!(reason:)
      Expense.where(source_payroll_period: @period, voided_at: nil).find_each do |expense|
        previous_status = expense.status
        expense.update!(
          voided_at:    Time.current,
          voided_by_id: @actor.id,
          void_reason:  I18n.t("payroll.insurance_expense_void_reason", reason: reason),
          status:       "cancelled"
        )
        log_audit(actor: @actor, auditable: expense, action: "insurance_expense_voided",
                  changes:  { status: [ previous_status, "cancelled" ] },
                  metadata: { payroll_period_id: @period.id, amount: expense.amount.to_s, reason: reason })
      end
    end

    private

    # Expense requires either a specific branch_id, or (when branch-less) a
    # full percentage/amount split across branches via expense_allocations —
    # there's no "unscoped, no split" option (see Expense#normalize_branch_mode).
    # Payroll is business-wide, so the cost arrives already attributed to the
    # branches where the insured employees worked; a single branch is recorded
    # directly, several are split proportionally. This mirrors
    # Finance::RecurringExpenseGenerator's use of AllocationCalculator for
    # shared templates.
    def build_employer_expense(business, employer_total, branch_totals)
      category = insurance_category(business)

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

    # Category names are unique per business regardless of case, so an existing
    # "social insurance" must be reused — a case-sensitive find_or_create_by!
    # missed it and the create failed, blocking payroll finalization (FS-D2).
    def insurance_category(business)
      business.expense_categories.find_by("LOWER(name) = ?", EXPENSE_CATEGORY_NAME.downcase) ||
        business.expense_categories.create!(name: EXPENSE_CATEGORY_NAME, active: true)
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
  end
end
