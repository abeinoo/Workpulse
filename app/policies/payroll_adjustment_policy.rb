class PayrollAdjustmentPolicy < ApplicationPolicy
  def index?
    same_business? && (super_admin? || area_manager? || branch_manager? || accountant?)
  end

  # new? uses a blank record (no user yet), so only check role — no employee-scope check.
  def new?
    same_business? && (super_admin? || area_manager? || branch_manager?)
  end

  # create? is called with the fully-built record (user_id already set by params).
  def create?  = can_manage_adjustment?

  # Only super admin may approve or reject.
  def approve? = can_review?
  def reject?  = can_review?
  # Creator (or super admin) can delete while still pending and period not locked.
  def destroy?
    return false unless record.pending_review?
    return false unless same_business?

    super_admin? || record.created_by_id == user.id
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.super_admin?
        scope.where(business: user.business)
      elsif user.area_manager?
        scope.where(business: user.business, user_id: employees_in_area)
      elsif user.branch_manager?
        scope.where(business: user.business, user_id: employees_in_branches)
      elsif user.accountant?
        scope.where(business: user.business)
      else
        scope.where(user_id: user.id, business: user.business)
      end
    end

    private

    def employees_in_area
      branch_ids = Branch.where(area_manager_id: user.id).pluck(:id)
      User.joins(:user_branches).where(user_branches: { branch_id: branch_ids }).select(:id)
    end

    def employees_in_branches
      User.joins(:user_branches)
          .where(user_branches: { branch_id: user.branch_ids })
          .select(:id)
    end
  end

  private

  def can_manage_adjustment?
    return false unless same_business?

    if super_admin? || accountant?
      true
    elsif area_manager?
      employee_in_area?
    elsif branch_manager?
      employee_in_branch?
    else
      false
    end
  end

  def can_review?
    return false unless same_business?
    super_admin?
  end

  def employee_in_branch?
    return false unless record.user
    (user.branch_ids & record.user.branch_ids).any?
  end

  def employee_in_area?
    return false unless record.user
    area_branch_ids = Branch.where(area_manager_id: user.id).pluck(:id)
    (area_branch_ids & record.user.branch_ids).any?
  end
end
