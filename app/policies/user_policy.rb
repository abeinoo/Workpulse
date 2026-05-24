class UserPolicy < ApplicationPolicy
  def index?          = can?(:view_employees) || owner? || manages_branch?
  def show?           = can?(:view_employees) || owner? || manages_this_user? || own_record?
  def create?         = can?(:manage_employees) || owner?
  def update?         = can?(:manage_employees) || owner? || own_record?
  def destroy?        = can?(:manage_employees) || owner?
  def reset_password?       = can?(:manage_employees) || owner?
  def transfer_ownership?   = user.owner? && record != user
  def toggle_active?        = can?(:manage_employees) || owner?

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.owner? || user.can?(:view_employees)
        scope.where(business: user.business)
      elsif user.manages_branch?
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
    record.manager_id == user.id
  end
end
