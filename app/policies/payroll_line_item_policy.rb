class PayrollLineItemPolicy < ApplicationPolicy
  def approve? = reviewable_action?
  def reject?  = reviewable_action?

  # ── Manual deduction waiver layer ───────────────────────────────────────────
  # Gated by its own dedicated permission (manage_payroll_deduction_waivers),
  # independent of the approve_adjustments review rule. Only manual deductions on
  # an unlocked, same-business period may be waived/restored.
  def waive_deduction?   = deduction_waiver_action?
  def restore_deduction? = deduction_waiver_action?

  # ── Addition/bonus cancellation layer ───────────────────────────────────────
  # Gated by its own dedicated permission (manage_payroll_addition_cancellations),
  # independent of the approve_adjustments review rule. Any item shown in the
  # "الإضافات والمكافآت" section (record.addition_cancellable?, which has no
  # type allowlist — see PayrollLineItem) on an unlocked, same-business period
  # may be cancelled — and only while not already cancelled (terminal).
  def cancel_addition? = addition_cancellation_action?

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

  def deduction_waiver_action?
    user.can?(:manage_payroll_deduction_waivers) &&
      !period_locked? && same_business_entry? && record.deduction_waivable?
  end

  def addition_cancellation_action?
    user.can?(:manage_payroll_addition_cancellations) &&
      !period_locked? && same_business_entry? &&
      record.addition_cancellable? && !record.addition_cancelled?
  end

  def period_locked?
    record.payroll_entry&.payroll_period&.locked?
  end

  def same_business_entry?
    record.payroll_entry&.payroll_period&.business_id == user.business_id
  end
end
