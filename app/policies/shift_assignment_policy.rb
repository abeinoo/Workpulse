class ShiftAssignmentPolicy < ApplicationPolicy
  def index?          = true  # scope handles isolation
  def show?           = can?(:view_shifts) || owner? || managing_branch? || managing_area? || own_record?
  def create?         = can?(:assign_shifts) || owner? || manages_area? || manages_branch? || direct_manager?
  def update?         = can?(:assign_shifts) || owner? || manages_area? || manages_branch? || direct_manager?
  def end_assignment? = can?(:assign_shifts) || owner? || managing_branch? || managing_area? || direct_manager?
  def destroy?        = owner?

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.owner?
        scope.for_business(user.business)
      elsif user.management_access?
        managed_ids  = EmployeeScope.new(user).relation.select(:id)
        branch_ids   = user.managed_branch_ids + user.area_managed_branch_ids
        base         = scope.where(user_id: managed_ids).or(scope.where(user_id: user.id))
        branch_ids.any? ? base.or(scope.where(branch_id: branch_ids)) : base
      else
        scope.where(user_id: user.id)
      end
    end
  end

  private

  def managing_branch?
    return false unless record.branch_id
    user.managed_branch_ids.include?(record.branch_id)
  end

  def managing_area?
    return false unless record.branch_id
    user.area_managed_branch_ids.include?(record.branch_id)
  end

  def own_record?
    record.user_id == user.id
  end

  def direct_manager?
    user.managed_employees.exists?
  end
end
