class ShiftRuleProfilePolicy < ApplicationPolicy
  def index?  = owner? || can?(:manage_shifts) || can?(:assign_shifts)
  def show?   = owner? || can?(:manage_shifts) || can?(:assign_shifts)
  def create? = owner? || can?(:manage_shifts)
  def update? = owner? || can?(:manage_shifts)
  def destroy? = owner? || can?(:manage_shifts)

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.for_business(user.business)
    end
  end
end
