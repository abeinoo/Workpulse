class AdvancePolicy < ApplicationPolicy
  def index?  = true
  def show?   = own_advance? || can?(:view_payroll) && same_business?(record.user)
  def create? = false  # created only via Requests::Approver

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.can?(:view_payroll)
        scope.joins(:user).where(users: { business_id: user.business_id })
      else
        scope.where(user_id: user.id)
      end
    end
  end

  private

  def own_advance?
    record.user_id == user.id
  end
end
