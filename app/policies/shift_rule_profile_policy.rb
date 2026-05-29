class ShiftRuleProfilePolicy < ApplicationPolicy
  def index?   = can?(:manage_shifts) || can?(:assign_shifts)
  def show?    = can?(:manage_shifts) || can?(:assign_shifts)
  def create?  = can?(:manage_shifts)
  def update?  = can?(:manage_shifts)
  def destroy? = can?(:manage_shifts)

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.for_business(user.business)
    end
  end
end
