class AdvancePolicy < ApplicationPolicy
  def index?  = true
  def show?   = own_advance? || managing_business? || managing_branch?
  def create? = false  # created only via Requests::Approver

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.owner? || user.can?(:view_payroll)
        scope.joins(:user).where(users: { business_id: user.business_id })
      elsif user.manages_branch?
        scope.joins(user: :user_branches)
             .where(user_branches: { branch_id: user.managed_branch_ids })
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
    (owner? || can?(:view_payroll)) && same_business?(record.user)
  end

  def managing_branch?
    manages_branch? && (user.managed_branch_ids & record.user.branch_ids).any?
  end
end
