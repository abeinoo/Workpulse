class PayrollAdjustmentPolicy < ApplicationPolicy
  def index?
    same_business? && (can?(:view_payroll) || can?(:manage_adjustments))
  end

  def show?
    return false unless same_business?

    # Creators see their own; subjects see adjustments about themselves;
    # reviewers see anything within their payroll view/manage scope.
    record.created_by_id == user.id ||
      record.user_id == user.id ||
      can?(:view_payroll) || can?(:manage_adjustments)
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

      # A user always sees adjustments they created (creator visibility) or that
      # are about themselves (subject visibility), on top of any reviewer scope.
      own = "payroll_adjustments.created_by_id = :me OR payroll_adjustments.user_id = :me"

      if user.can?(:view_payroll) || user.can?(:manage_adjustments)
        reviewable_ids =
          if (configured = user.scope_for(:view_payroll))
            EmployeeScope.new(user).for_scope(configured).select(:id)
          else
            EmployeeScope.new(user).relation.select(:id)
          end
        business_scoped.where(
          "payroll_adjustments.user_id IN (:ids) OR #{own}",
          ids: reviewable_ids, me: user.id
        )
      else
        business_scoped.where(own, me: user.id)
      end
    end
  end

  private

  def period_locked?
    period = record.respond_to?(:payroll_period) ? record.payroll_period : nil
    period&.locked?
  end

  def can_review?
    return false unless same_business?

    # The single approval rule for the entire payroll system.
    Payroll::AdjustmentApproval.permitted?(reviewer: user, creator: record.created_by_id)
  end
end
