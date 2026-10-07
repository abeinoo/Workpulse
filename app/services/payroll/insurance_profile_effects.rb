module Payroll
  # Attendance & Payroll implementation of the Workforce
  # Employee::InsuranceProfileEffects contract (registered in
  # config/initializers/employee_insurance_profile_effects.rb). Both operations
  # are the existing behaviour, unchanged: the recalculation the insurance
  # updater triggers and the payroll notice the insurance edit form shows.
  module InsuranceProfileEffects
    module_function

    # Re-derives the employee's entry in every open (not finalized / paid)
    # period that has one; locked periods keep their snapshot.
    def profile_changed(user:, actor:)
      Payroll::EntryRecalculator.recalculate_all_open_periods_for(user: user, triggered_by: actor)
    end

    # The same periods profile_changed recalculates, described for the form:
    #   :none      — the employee has never appeared in any payroll period
    #   :active    — exactly one non-finalized period (draft / under_review /
    #                branch_review_completed) has an entry for them; finalized
    #                history is irrelevant here
    #   :mixed     — more than one non-finalized period at once (e.g. next
    #                month's draft generated before this month's review
    #                finished) — ambiguous which one to name
    #   :finalized — every period they appear in is finalized / paid; nothing
    #                open to reflect the change into
    # Informational only: the insurance snapshot rule itself is
    # Payroll::EntryCalculator#resolve_insurance_snapshot.
    def payroll_notice_for(user:)
      periods = PayrollPeriod.where(id: user.payroll_entries.select(:payroll_period_id))
      active  = periods.reject(&:locked?)

      if periods.none?
        :none
      elsif active.size > 1
        :mixed
      elsif active.size == 1
        :active
      else
        :finalized
      end
    end
  end
end
