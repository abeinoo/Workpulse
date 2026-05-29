class ShiftAssignmentPolicy < ApplicationPolicy
  def index?          = true  # scope handles isolation
  def show?           = can?(:view_shifts) || can?(:assign_shifts) || own_record?
  def create?         = can?(:assign_shifts)
  def update?         = can?(:assign_shifts)
  def end_assignment? = can?(:assign_shifts)

  # Hard-delete only when the assignment has no attendance records.
  def destroy?
    return false unless can?(:assign_shifts)
    record.deletable?
  end

  def bulk_assign? = can?(:assign_shifts)
  def bulk_end?    = can?(:assign_shifts)
  def bulk_delete? = can?(:assign_shifts)

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.can?(:assign_shifts) || user.can?(:view_shifts)
        managed_ids = EmployeeScope.new(user).relation.select(:id)
        branch_ids  = user.managed_branch_ids + user.area_managed_branch_ids
        base        = scope.where(user_id: managed_ids).or(scope.where(user_id: user.id))
        branch_ids.any? ? base.or(scope.where(branch_id: branch_ids)) : base
      else
        scope.where(user_id: user.id)
      end
    end
  end

  private

  def own_record?
    record.user_id == user.id
  end
end
