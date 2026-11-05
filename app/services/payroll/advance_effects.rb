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

    # A salary advance is a payment against salary: refused while the
    # employee's salary payment is on hold (any active SalaryPaymentHold).
    def advance_payment_refusal(request:)
      hold = SalaryPaymentHold.active.find_by(user_id: request.user_id, business_id: request.user.business_id)
      return nil unless hold

      I18n.t("salary_payment_holds.errors.advance_blocked",
             reason: I18n.t("salary_payment_holds.reasons.#{hold.reason}"))
    end
  end
end
