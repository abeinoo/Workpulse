class ShiftPolicy < ApplicationPolicy
  def index?   = super_admin? || branch_manager?
  def show?    = super_admin? || branch_manager?
  def create?  = super_admin?
  def update?  = super_admin?
  def destroy? = super_admin?

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.for_business(user.business).active
    end
  end
end
