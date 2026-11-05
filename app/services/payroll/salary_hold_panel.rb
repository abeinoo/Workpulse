module Payroll
  # The Salary Payment Hold section of the employee page, contributed through
  # the Workforce contract Employee::ProfilePanels (via Payroll::EmployeeSalaryPanel,
  # its registered handler). Read-only: what SalaryPaymentHoldPolicy lets the
  # viewer see — every hold of the employee, newest first (history is never
  # deleted), the amounts withheld under them that are still held or payable,
  # and the place / release forms when the viewer may manage holds.
  module SalaryHoldPanel
    PARTIAL = "admin/salary_payment_holds/employee_panel".freeze

    module_function

    def call(viewer:, employee:)
      probe  = SalaryPaymentHold.new(business_id: employee.business_id, user_id: employee.id)
      policy = SalaryPaymentHoldPolicy.new(viewer, probe)
      return nil unless policy.show?

      holds = SalaryPaymentHold.where(business_id: employee.business_id, user_id: employee.id)
                               .includes(:created_by, :released_by).order(created_at: :desc, id: :desc).to_a
      outstanding = SalaryPaymentWithholding.outstanding.where(salary_payment_hold_id: holds.map(&:id))
                                            .includes(:salary_payment_hold, payroll_entry: :payroll_period)
                                            .order(:id).to_a

      Employee::ProfilePanels::Panel.new(
        partial: PARTIAL,
        locals:  { employee: employee, holds: holds, active_hold: holds.find(&:active?),
                   outstanding: outstanding, can_manage: policy.create?,
                   held_total: outstanding.select(&:held?).sum { |w| w.amount.to_d },
                   payable_total: outstanding.select(&:payable?).sum { |w| w.amount.to_d } }
      )
    end
  end
end
