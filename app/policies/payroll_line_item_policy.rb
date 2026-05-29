class PayrollLineItemPolicy < ApplicationPolicy
  def approve? = !period_locked? && can?(:approve_adjustments) && same_business_entry?
  def reject?  = !period_locked? && can?(:approve_adjustments) && same_business_entry?
  def waive?   = !period_locked? && can?(:approve_adjustments) && same_business_entry?

  class Scope < ApplicationPolicy::Scope
    def resolve
      business_items = scope.joins(payroll_entry: :payroll_period)
                            .where(payroll_periods: { business_id: user.business_id })

      if user.can?(:view_payroll)
        configured = user.scope_for(:view_payroll)
        emp_ids    = if configured
                       EmployeeScope.new(user).for_scope(configured).select(:id)
                     else
                       EmployeeScope.new(user).relation.select(:id)
                     end
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

  def same_business_entry?
    record.payroll_entry&.payroll_period&.business_id == user.business_id
  end
end
