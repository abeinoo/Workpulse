class PayrollLineItemPolicy < ApplicationPolicy
  # Only super admins may approve or reject (manual_deduction / pending bonus review).
  def approve? = super_admin? && same_business_entry?
  def reject?  = super_admin? && same_business_entry?
  # Super admins and the employee's direct branch manager may waive deductions.
  def waive?   = overriding?

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.super_admin? || user.accountant?
        scope.joins(payroll_entry: :payroll_period)
             .where(payroll_periods: { business_id: user.business_id })
      elsif user.area_manager?
        area_branch_ids = Branch.where(area_manager_id: user.id).pluck(:id)
        managed_emp_ids = UserBranch.where(branch_id: area_branch_ids).select(:user_id)
        scope.joins(payroll_entry: :payroll_period)
             .where(payroll_periods: { business_id: user.business_id })
             .where(payroll_entries: { user_id: managed_emp_ids })
      elsif user.branch_manager?
        managed_emp_ids = UserBranch.where(branch_id: user.branch_ids).select(:user_id)
        scope.joins(payroll_entry: :payroll_period)
             .where(payroll_periods: { business_id: user.business_id })
             .where(payroll_entries: { user_id: managed_emp_ids })
      else
        scope.joins(:payroll_entry).where(payroll_entries: { user_id: user.id })
      end
    end
  end

  private

  def overriding?
    return false unless same_business_entry?
    super_admin? || (branch_manager? && direct_manager_of_employee?)
  end

  def same_business_entry?
    record.payroll_entry&.payroll_period&.business_id == user.business_id
  end

  def direct_manager_of_employee?
    employee_branch_ids = record.payroll_entry.user.branch_ids
    (user.branch_ids & employee_branch_ids).any?
  end
end
