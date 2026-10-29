class BranchPolicy < ApplicationPolicy
  def index?   = can?(:manage_branches)
  def show?    = can?(:manage_branches)
  def create?  = can?(:manage_branches)
  def update?  = can?(:manage_branches)
  def destroy? = can?(:manage_branches)
  def deactivate? = can?(:manage_branches)
  def reactivate? = can?(:manage_branches)

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.can?(:manage_branches)
        scope.for_business(user.business)
      else
        scope.none
      end
    end
  end
end
