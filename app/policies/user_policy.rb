class UserPolicy < ApplicationPolicy
  def index?   = super_admin? || branch_manager?
  def show?    = super_admin? || manages_this_user? || own_record?
  def create?  = super_admin?
  def update?  = super_admin? || own_record?
  def destroy? = super_admin?

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.super_admin?
        scope.where(business: user.business)
      elsif user.branch_manager?
        # Managers see themselves + their directly assigned employees
        scope.where(id: user.id)
             .or(scope.where(manager_id: user.id))
      else
        scope.where(id: user.id)
      end
    end
  end

  private

  def own_record?
    record == user
  end

  def manages_this_user?
    branch_manager? && record.manager_id == user.id
  end
end
