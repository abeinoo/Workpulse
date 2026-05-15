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
      elsif user.area_manager? || user.branch_manager?
        scope.where(branch_id: user.branch_ids)
      else
        scope.where(user_id: user.id)
      end
    end
  end

  private

  def managing_branch?
    branch_manager? && record.branch_id && user.branch_ids.include?(record.branch_id)
  end

  def managing_area?
    area_manager? && record.branch_id && user.branch_ids.include?(record.branch_id)
  end

  def own_record?
    record.user_id == user.id
  end
end
