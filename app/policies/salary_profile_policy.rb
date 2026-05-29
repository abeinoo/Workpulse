class SalaryProfilePolicy < ApplicationPolicy
  def index?   = viewable?
  def show?    = viewable?
  def create?  = can?(:manage_salary_profiles)
  def update?  = can?(:manage_salary_profiles) && record.active?
  def destroy? = false

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.can?(:manage_salary_profiles) || user.can?(:view_payroll)
        scope.joins(:user).where(users: { business_id: user.business_id })
      else
        scope.where(user_id: user.id)
      end
    end
  end

  private

  def viewable?
    can?(:manage_salary_profiles) || can?(:view_payroll) || own_record?
  end

  def own_record?
    record.user_id == user.id
  end
end
