class PermissionRolePolicy < ApplicationPolicy
  def index?   = can?(:manage_roles)
  def show?    = can?(:manage_roles)
  def create?  = can?(:manage_roles)
  def update?  = can?(:manage_roles)
  # Owner can always delete any role; a manage_roles user can delete any role
  # they did not assign to themselves (we leave that nuance to the controller).
  def destroy? = can?(:manage_roles)

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(business: user.business)
    end
  end
end
