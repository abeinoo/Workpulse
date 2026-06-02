class PayrollLineItemPolicy < ApplicationPolicy
  def approve? = reviewable_action?
  def reject?  = reviewable_action?
  def waive?   = reviewable_action?

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

  # Same single approval rule as adjustments. For attendance/system items the
  # source_creator is nil, so the creator != approver clause is vacuous and only
  # the approve_adjustments permission is required (unchanged from before).
  def reviewable_action?
    !period_locked? && same_business_entry? &&
      Payroll::AdjustmentApproval.permitted?(reviewer: user, creator: record.source_creator)
  end

  def period_locked?
    record.payroll_entry&.payroll_period&.locked?
  end

  def same_business_entry?
    record.payroll_entry&.payroll_period&.business_id == user.business_id
  end
end
