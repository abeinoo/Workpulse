class PayrollAdjustmentPolicy < ApplicationPolicy
  def index?
    same_business? && (can?(:view_payroll) || owner? || manages_area? || manages_branch?)
  end

  def new?
    same_business? && (owner? || manages_area? || manages_branch?)
  end

  def create?  = can_manage_adjustment?
  def approve? = can_review?
  def reject?  = can_review?

  def destroy?
    return false unless record.pending_review?
    return false unless same_business?

    owner? || record.created_by_id == user.id
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.owner? || user.can?(:view_payroll)
        scope.where(business: user.business)
      elsif user.manages_area?
        scope.where(business: user.business, user_id: employees_in_area)
      elsif user.manages_branch?
        scope.where(business: user.business, user_id: employees_in_branches)
      else
        scope.where(user_id: user.id, business: user.business)
      end
    end

    private

    def employees_in_area
      User.joins(:user_branches).where(user_branches: { branch_id: user.area_managed_branch_ids }).select(:id)
    end

    def employees_in_branches
      User.joins(:user_branches)
          .where(user_branches: { branch_id: user.managed_branch_ids })
          .select(:id)
    end
  end

  private

  def can_manage_adjustment?
    return false unless same_business?

    if can?(:manage_adjustments) || owner?
      true
    elsif manages_area?
      employee_in_area?
    elsif manages_branch?
      employee_in_branch?
    else
      false
    end
  end

  def can_review?
    return false unless same_business?
    can?(:approve_adjustments) || owner?
  end

  def employee_in_branch?
    return false unless record.user
    (user.managed_branch_ids & record.user.branch_ids).any?
  end

  def employee_in_area?
    return false unless record.user
    (user.area_managed_branch_ids & record.user.branch_ids).any?
  end
end
