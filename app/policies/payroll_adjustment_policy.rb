class PayrollAdjustmentPolicy < ApplicationPolicy
  def index?
    same_business? && (can?(:view_payroll) || can?(:manage_adjustments))
  end

  def new?
    same_business? && can?(:manage_adjustments)
  end

  def create?
    return false if period_locked?
    same_business? && can?(:manage_adjustments) && record.user.present?
  end

  def approve? = can_review?
  def reject?  = can_review?

  def destroy?
    return false if period_locked?
    return false unless record.pending_review?
    return false unless same_business?

    can?(:manage_adjustments)
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      business_scoped = scope.where(business: user.business)

      if user.can?(:view_payroll) || user.can?(:manage_adjustments)
        if (configured = user.scope_for(:view_payroll))
          filter_by_data_scope(business_scoped, configured)
        else
          business_scoped.where(user_id: EmployeeScope.new(user).relation.select(:id))
        end
      else
        business_scoped.where(user_id: user.id)
      end
    end
  end

  private

  def period_locked?
    period = record.respond_to?(:payroll_period) ? record.payroll_period : nil
    period&.locked?
  end

  def can_review?
    same_business? && can?(:approve_adjustments)
  end
end
