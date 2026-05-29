class UserPolicy < ApplicationPolicy
  def index?          = can?(:view_employees)
  def show?           = can?(:view_employees) || own_record?
  def create?         = can?(:manage_employees)
  def update?         = can?(:manage_employees) || own_record?
  def destroy?        = can?(:manage_employees)
  def reset_password?       = can?(:manage_employees)
  def transfer_ownership?   = user.owner? && record != user
  def toggle_active?        = can?(:manage_employees)

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.can?(:view_employees)
        configured  = user.scope_for(:view_employees)
        base        = scope.where(business: user.business)
        managed_ids = EmployeeScope.new(user).relation.select(:id)
        if configured
          filter_by_data_scope(base, configured, user_id_column: :id)
        else
          base.where(id: user.id).or(base.where(id: managed_ids))
        end
      else
        scope.where(id: user.id)
      end
    end
  end

  private

  def own_record?
    record == user
  end
end
