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

    # The same periods profile_changed recalculates, described for the form.
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
