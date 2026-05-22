class BranchPolicy < ApplicationPolicy
  def index?   = can?(:manage_branches) || owner? || manages_branch?
  def show?    = can?(:manage_branches) || owner? || managing_this_branch?
  def create?  = can?(:manage_branches) || owner?
  def update?  = can?(:manage_branches) || owner? || managing_this_branch?
  def destroy? = can?(:manage_branches) || owner?

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.owner? || user.can?(:manage_branches)
        scope.for_business(user.business)
      else
        user.branches.active
      end
    end
  end

  private

  def managing_this_branch?
    user.branches.exists?(record.id) ||
      record.branch_manager_id == user.id ||
      record.area_manager_id == user.id
  end
end
