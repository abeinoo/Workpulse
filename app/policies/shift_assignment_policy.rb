class ShiftAssignmentPolicy < ApplicationPolicy
  def index?          = super_admin? || area_manager? || branch_manager? || employee?
  def show?           = super_admin? || managing_branch? || managing_area? || own_record?
  def create?         = super_admin? || area_manager? || branch_manager?
  def update?         = super_admin? || area_manager? || branch_manager?
  def end_assignment? = super_admin? || managing_branch? || managing_area?
  def destroy?        = super_admin?

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.super_admin?
        scope.for_business(user.business)
      elsif user.area_manager?
        scope.where(branch_id: user.branch_ids)
      elsif user.branch_manager?
        # Include own assignment + assignments for all managed branches
        # (branch_manager_id takes precedence over user_branches).
        managed_ids = Branch.where(branch_manager_id: user.id).pluck(:id)
        visible_branch_ids = (managed_ids + user.branch_ids).uniq
        scope.where(user_id: user.id).or(scope.where(branch_id: visible_branch_ids))
      else
        scope.where(user_id: user.id)
      end
    end
  end

  private

  def managing_branch?
    return false unless branch_manager? && record.branch_id

    user.branch_ids.include?(record.branch_id) ||
      Branch.exists?(id: record.branch_id, branch_manager_id: user.id)
  end

  def managing_area?
    area_manager? && record.branch_id && user.branch_ids.include?(record.branch_id)
  end

  def own_record?
    record.user_id == user.id
  end
end
