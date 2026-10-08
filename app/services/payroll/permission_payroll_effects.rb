module Payroll
  # Attendance & Payroll implementation of the Workforce
  # Requests::PermissionPayrollEffects contract (registered in
  # config/initializers/request_permission_payroll_effects.rb):
  #
  #   permission_approved  → Payroll::PermissionApplier (adjusts the penalty line
  #                          of an open period, or does nothing)
  #   permission_cancelled → Payroll::PermissionReverter (restores the full
  #                          penalty; :reverted, or :refused for a finalized / paid
  #                          period)
  #
  # Calls nothing in Workforce.
  module PermissionPayrollEffects
    module_function

    def permission_approved(request:)
      Payroll::PermissionApplier.call(request)
    end

    def permission_cancelled(request:)
      Payroll::PermissionReverter.call(request)
    end
  end
end
