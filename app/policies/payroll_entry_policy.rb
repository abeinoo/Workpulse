class PayrollEntryPolicy < ApplicationPolicy
  def index?  = can?(:view_payroll) || owner? || manages_area? || manages_branch?
  def show?   = can?(:view_payroll) || owner? || manages_area? || manages_branch? || own_entry?
  def update? = can?(:manage_payroll) || owner?

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.owner? || user.can?(:view_payroll)
        scope.joins(:payroll_period).where(payroll_periods: { business_id: user.business_id })
      elsif user.manages_area?
        managed_emp_ids = UserBranch.where(branch_id: user.area_managed_branch_ids).select(:user_id)
        scope.joins(:payroll_period)
             .where(payroll_periods: { business_id: user.business_id })
             .where(user_id: managed_emp_ids)
      elsif user.manages_branch?
        managed_emp_ids = UserBranch.where(branch_id: user.managed_branch_ids).select(:user_id)
        scope.joins(:payroll_period)
             .where(payroll_periods: { business_id: user.business_id })
             .where(user_id: managed_emp_ids)
      else
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
