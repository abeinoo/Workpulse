class PayrollLineItemPolicy < ApplicationPolicy
  def approve? = (can?(:approve_adjustments) || owner?) && same_business_entry?
  def reject?  = (can?(:approve_adjustments) || owner?) && same_business_entry?
  def waive?   = overriding?

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.owner? || user.can?(:view_payroll)
        scope.joins(payroll_entry: :payroll_period)
             .where(payroll_periods: { business_id: user.business_id })
      elsif user.manages_area?
        managed_emp_ids = UserBranch.where(branch_id: user.area_managed_branch_ids).select(:user_id)
        scope.joins(payroll_entry: :payroll_period)
             .where(payroll_periods: { business_id: user.business_id })
             .where(payroll_entries: { user_id: managed_emp_ids })
      elsif user.manages_branch?
        managed_emp_ids = UserBranch.where(branch_id: user.managed_branch_ids).select(:user_id)
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
    can?(:approve_adjustments) || owner? || direct_manager_of_employee?
  end

  def same_business_entry?
    record.payroll_entry&.payroll_period&.business_id == user.business_id
  end

  def direct_manager_of_employee?
    employee_branch_ids = record.payroll_entry.user.branch_ids
    (user.managed_branch_ids & employee_branch_ids).any?
  end
end
