class ShiftPolicy < ApplicationPolicy
  def index?   = can?(:view_shifts) || owner? || manages_branch?
  def show?    = can?(:view_shifts) || owner? || manages_branch?
  def create?  = can?(:manage_shifts) || owner?
  def update?  = can?(:manage_shifts) || owner?
  def destroy? = can?(:manage_shifts) || owner?

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.for_business(user.business).active
    end
  end
end
