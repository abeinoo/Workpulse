class SalaryProfilePolicy < ApplicationPolicy
  def index?   = viewable?
  def show?    = viewable?
  def create?  = can?(:manage_salary_profiles) || owner?
  def update?  = (can?(:manage_salary_profiles) || owner?) && record.active?
  def destroy? = false

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.owner? || user.can?(:manage_salary_profiles) || user.can?(:view_payroll)
        scope.joins(:user).where(users: { business_id: user.business_id })
      elsif user.manages_branch?
        managed_user_ids = User.joins(:user_branches)
                               .where(user_branches: { branch_id: user.managed_branch_ids, active: true })
                               .select(:id)
        scope.where(user_id: managed_user_ids)
      else
        scope.where(user_id: user.id)
      end
    end
  end

  private

  def viewable?
    can?(:manage_salary_profiles) || can?(:view_payroll) || owner? || managing_profile_owner? || own_record?
  end

  def own_record?
    record.user_id == user.id
  end

  def managing_profile_owner?
    UserBranch.where(user_id: record.user_id, branch_id: user.managed_branch_ids, active: true).exists?
  end
end
