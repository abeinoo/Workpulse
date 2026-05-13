class BranchPolicy < ApplicationPolicy
  def index?   = super_admin? || branch_manager?
  def show?    = super_admin? || managing_this_branch?
  def create?  = super_admin?
  def update?  = super_admin? || managing_this_branch?
  def destroy? = super_admin?

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.super_admin?
        scope.for_business(user.business)
      else
        user.branches.active
      end
    end
  end

  private

  def managing_this_branch?
    branch_manager? && user.branches.exists?(record.id)
  end
end
