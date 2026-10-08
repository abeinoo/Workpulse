module Payroll
  # Attendance & Payroll implementation of the Workforce
  # Requests::PermissionPayrollEffects contract (registered in
  # config/initializers/request_permission_payroll_effects.rb).
  #
  # permission_approved is the existing PermissionApplier (adjusts the penalty
  # line of an open period, or does nothing). permission_cancelled still
  # delegates to the revert that lives in Workforce today
  # (Requests::Canceller.revert_permission_payroll) — Pilot 9 M4 moves that logic
  # here; until then the behaviour is exactly the current one.
  module PermissionPayrollEffects
    module_function

    def permission_approved(request:)
      Payroll::PermissionApplier.call(request)
    end

    def permission_cancelled(request:)
      Requests::Canceller.revert_permission_payroll(request)
    end
  end
end
