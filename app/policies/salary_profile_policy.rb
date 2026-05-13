class SalaryProfilePolicy < ApplicationPolicy
  def index?   = viewable?
  def show?    = viewable?
  def create?  = super_admin?
  # Only the currently active profile may be edited; historical ones are immutable.
  def update?  = super_admin? && record.active?
  def destroy? = false

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.super_admin? || user.accountant?
        scope.joins(:user).where(users: { business_id: user.business_id })
      elsif user.branch_manager?
        managed_user_ids = User.joins(:user_branches)
                               .where(user_branches: { branch_id: user.branch_ids, active: true })
                               .select(:id)
        scope.where(user_id: managed_user_ids)
      else
        scope.where(user_id: user.id)
      end
    end
  end

  private

  def viewable?
    super_admin? || accountant? || managing_profile_owner? || own_record?
  end

  def own_record?
    record.user_id == user.id
  end

  def managing_profile_owner?
    branch_manager? &&
      UserBranch.where(user_id: record.user_id, branch_id: user.branch_ids, active: true).exists?
  end
end
