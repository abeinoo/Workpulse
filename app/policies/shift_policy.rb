class ShiftPolicy < ApplicationPolicy
  def index?   = can?(:view_shifts) || can?(:manage_shifts) || can?(:assign_shifts)
  def show?    = can?(:view_shifts) || can?(:manage_shifts) || can?(:assign_shifts) || own_shift_assigned?
  def create?  = can?(:manage_shifts)
  def update?  = can?(:manage_shifts)
  def destroy? = can?(:manage_shifts)

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.for_business(user.business).active
    end
  end

  private

  def own_shift_assigned?
    ShiftAssignment.where(user: user, shift: record).exists?
  end
end
