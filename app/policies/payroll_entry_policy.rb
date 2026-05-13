class PayrollEntryPolicy < ApplicationPolicy
  def index?  = super_admin? || area_manager? || branch_manager? || accountant?
  def show?   = super_admin? || area_manager? || branch_manager? || accountant? || own_entry?
  def update? = super_admin? || accountant?

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.super_admin? || user.accountant?
        scope.joins(:payroll_period).where(payroll_periods: { business_id: user.business_id })
      elsif user.area_manager?
        area_branch_ids  = Branch.where(area_manager_id: user.id).pluck(:id)
        managed_emp_ids  = UserBranch.where(branch_id: area_branch_ids).select(:user_id)
        scope.joins(:payroll_period)
             .where(payroll_periods: { business_id: user.business_id })
             .where(user_id: managed_emp_ids)
      elsif user.branch_manager?
        managed_emp_ids = UserBranch.where(branch_id: user.branch_ids).select(:user_id)
        scope.joins(:payroll_period)
             .where(payroll_periods: { business_id: user.business_id })
             .where(user_id: managed_emp_ids)
      else
        # Employees only see their own entries in finalized or paid periods.
        scope.joins(:payroll_period)
             .where(user_id: user.id)
             .where(payroll_periods: { status: %w[finalized paid] })
      end
    end
  end

  private

  def own_entry?
    record.user_id == user.id
  end
end
