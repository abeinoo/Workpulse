class PermissionRolePolicy < ApplicationPolicy
  def index?   = can?(:manage_roles)
  def show?    = can?(:manage_roles)
  def create?  = can?(:manage_roles)
  # Editing or deleting a role is limited to roles whose permissions the actor
  # holds themselves — no one manages a role above their own (PermissionGrants).
  def update?  = can?(:manage_roles) && manageable?
  def destroy? = can?(:manage_roles) && manageable?

  class Scope < ApplicationPolicy::Scope
    def resolve
      scope.where(business: user.business)
    end
  end

  private

  def manageable?
    record.is_a?(Class) || OrganizationAccess::PermissionGrants.manageable_role?(user, record)
  end
end
