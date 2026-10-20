module Payroll
  # Attendance & Payroll implementation of the Workforce Requests::AdvanceEffects
  # contract (registered in config/initializers/request_advance_effects.rb):
  # records the Advance of a paid salary-advance request (Batch A — Advance
  # boundary). Runs in the caller's transaction (Requests::Approver#pay).
  #
  # Unchanged from the Advance.create! this replaces in the approver: the full
  # request amount as total and remaining, status active, issued at paid_at.
  # The Advance is then deducted by Payroll::AdvanceDeductor and settled by
  # Payroll::Approver when its period is paid.
  module AdvanceEffects
    module_function

    def advance_paid(request:, paid_at:)
      Advance.create!(
        user:             request.user,
        employee_request: request,
        total_amount:     request.amount,
        remaining_amount: request.amount,
        status:           "active",
        issued_at:        paid_at
      )
      nil
    end
  end
end
