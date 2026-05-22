class ShiftPolicy < ApplicationPolicy
  def index?   = can?(:view_shifts) || owner? || manages_branch?
  def show?    = can?(:view_shifts) || owner? || manages_branch? || own_shift_assigned?
  def create?  = can?(:manage_shifts) || owner?
  def update?  = can?(:manage_shifts) || owner?
  def destroy? = can?(:manage_shifts) || owner?

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
