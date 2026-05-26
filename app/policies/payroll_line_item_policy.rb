class PayrollLineItemPolicy < ApplicationPolicy
  def approve? = !period_locked? && (can?(:approve_adjustments) || owner?) && same_business_entry?
  def reject?  = !period_locked? && (can?(:approve_adjustments) || owner?) && same_business_entry?
  def waive?   = !period_locked? && overriding?

  class Scope < ApplicationPolicy::Scope
    def resolve
      business_items = scope.joins(payroll_entry: :payroll_period)
                            .where(payroll_periods: { business_id: user.business_id })

      if user.owner?
        business_items
      elsif user.can?(:view_payroll)
        configured = user.scope_for(:view_payroll)
        emp_ids    = if configured
                       EmployeeScope.new(user).for_scope(configured).select(:id)
                     else
                       EmployeeScope.new(user).relation.select(:id)
                     end
        business_items.where(payroll_entries: { user_id: emp_ids })
      elsif user.management_access?
        emp_ids = EmployeeScope.new(user).relation.select(:id)
        business_items.where(payroll_entries: { user_id: emp_ids })
      else
        scope.joins(:payroll_entry).where(payroll_entries: { user_id: user.id })
      end
    end
  end

  private

  def period_locked?
    record.payroll_entry&.payroll_period&.locked?
  end

  def overriding?
    return false unless same_business_entry?
    can?(:approve_adjustments) || owner? || manages_employee_in_scope?
  end

  def same_business_entry?
    record.payroll_entry&.payroll_period&.business_id == user.business_id
  end

  def manages_employee_in_scope?
    return false unless record.payroll_entry&.user
    EmployeeScope.new(user).includes?(record.payroll_entry.user_id)
  end
end
