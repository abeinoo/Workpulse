module Payroll
  # Attendance & Payroll implementation of the Workforce contract
  # Employee::PayrollDateProtection (R3.2; roadmap revision 19, OD-1, OD-10,
  # OD-12, OD-13, §19.14), registered in
  # config/initializers/employee_payroll_date_protection.rb.
  #
  # A period is protected once it is under review or later (D4); the contract
  # speaks in Workforce stages, never payroll statuses. Every period of the
  # business counts — whether or not the employee has an entry in it (OD-10).
  #
  # lock_protected_range follows the §19.14 protocol: inside the caller's
  # transaction it takes the business's payroll-status lock in SHARED mode, then
  # locks EVERY period row of the business overlapping the dates FOR SHARE
  # (ORDER BY id, as Payroll::AdjustmentEditor) with NO status filter, and only
  # then reads the status. A filter on status would let a Draft period that a
  # concurrent submission is about to commit as Under Review slip through.
  module RequirementDateProtection
    STAGE_BY_STATUS = {
      "under_review"            => :in_review,
      "branch_review_completed" => :in_review,
      "finalized"               => :finalized,
      "paid"                    => :finalized
    }.freeze

    module_function

    def lock_protected_range(business_id:, from:, through:)
      return nil if from > through

      StatusLock.shared!(business_id: business_id)
      periods = overlapping(business_id, from, through).order(:id).lock("FOR SHARE").to_a
      protected_answers(periods).first
    end

    def protected_ranges(business_id:, from:, through:)
      return [] if from > through

      protected_answers(overlapping(business_id, from, through).to_a)
    end

    def overlapping(business_id, from, through)
      PayrollPeriod.where(business_id: business_id)
                   .where("(period_year * 12 + period_month) BETWEEN ? AND ?",
                          (from.year * 12) + from.month, (through.year * 12) + through.month)
    end

    def protected_answers(periods)
      periods.filter_map do |period|
        stage = STAGE_BY_STATUS[period.status]
        next unless stage

        Employee::PayrollDateProtection::Protected.new(starts_on: period.period_start, ends_on: period.period_end,
                                                       stage: stage)
      end.sort_by(&:starts_on)
    end
    private_class_method :overlapping, :protected_answers
  end
end
