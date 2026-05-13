class AdvancePolicy < ApplicationPolicy
  def index?  = true
  def show?   = own_advance? || managing_business? || managing_branch?
  def create? = false  # created only via Requests::Approver

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.super_admin? || user.accountant?
        scope.joins(:user).where(users: { business_id: user.business_id })
      elsif user.branch_manager?
        # Advances for employees who belong to any of the manager's branches.
        scope.joins(user: :user_branches)
             .where(user_branches: { branch_id: user.branch_ids })
      else
        scope.where(user_id: user.id)
      end
    end
  end

  private

  def own_advance?
    record.user_id == user.id
  end

  def managing_business?
    (super_admin? || accountant?) && same_business?(record.user)
  end

  def managing_branch?
    branch_manager? && (user.branch_ids & record.user.branch_ids).any?
  end
end
