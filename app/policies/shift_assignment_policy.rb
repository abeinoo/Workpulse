class ShiftAssignmentPolicy < ApplicationPolicy
  def index?          = true  # scope handles isolation
  def show?           = can?(:view_shifts) || owner? || managing_branch? || managing_area? || own_record?
  def create?         = can?(:assign_shifts) || owner? || manages_area? || manages_branch?
  def update?         = can?(:assign_shifts) || owner? || manages_area? || manages_branch?
  def end_assignment? = can?(:assign_shifts) || owner? || managing_branch? || managing_area?
  def destroy?        = owner?

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.owner?
        scope.for_business(user.business)
      elsif user.manages_area?
        scope.where(branch_id: user.area_managed_branch_ids)
      elsif user.manages_branch? || user.can?(:assign_shifts)
        scope.where(user_id: user.id).or(scope.where(branch_id: user.managed_branch_ids))
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
end
