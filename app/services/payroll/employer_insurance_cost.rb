module Payroll
  # The employer social-insurance cost of a payroll period: the total of the
  # insured entries' employer contributions, that total attributed to branches,
  # and the part attributed to no branch — the floating employees' (no home
  # branch), whose cost stays business-level, never on a fallback branch
  # (total = by_branch sum + unallocated). It is the payload Payroll hands to
  # Payroll::FinalizationEffects.period_finalized (module-boundaries.md
  # §14.1 A, "employer_insurance_cost_by_branch"), so the domain that records
  # the cost never reads payroll entries or shift assignments itself.
  #
  # Moved unchanged from Payroll::InsuranceExpenseGenerator (Milestone 2 —
  # Finance & Sales Expenses, M4). Reads only: payroll entries (this domain),
  # ShiftAssignment.branch_ids_by_user (Workforce read, AP → WF) and the
  # business's branches (Organization & Access read).
  class EmployerInsuranceCost
    Totals = Struct.new(:total, :by_branch, :unallocated, keyword_init: true)

    def self.for(period)
      new(period).call
    end

    def initialize(period)
      @period = period
    end

    def call
      insured_entries = @period.payroll_entries.where(insured: true)
      rows            = insured_entries.pluck(:user_id, :employer_insurance_amount)
      floating        = ShiftAssignment.floating_user_ids(rows.map(&:first), from: @period.period_start,
                                                                             to:   @period.period_end).to_set
      floating_rows, attributed_rows = rows.partition { |user_id, _| floating.include?(user_id) }

      Totals.new(
        total:       insured_entries.sum(:employer_insurance_amount),
        by_branch:   employer_total_by_branch(attributed_rows),
        unallocated: floating_rows.sum(BigDecimal("0")) { |_, amount| amount }
      )
    end

    private

    # {branch_id => employer_contribution_sum} for the insured entries, keyed by
    # each employee's branch during the period (latest-effective assignment
    # wins — see ShiftAssignment.branch_ids_by_user). Employees with no shift
    # assignment during the period (or if the business has no branches at all)
    # fall back to the business's first branch so attribution never blocks
    # expense creation — this is cost bookkeeping, not a physical-location claim.
    # Floating employees are not in `rows` (see #call).
    def employer_total_by_branch(rows)
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
