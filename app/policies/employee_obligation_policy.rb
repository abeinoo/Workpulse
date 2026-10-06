class EmployeeObligationPolicy < ApplicationPolicy
  def index?  = can?(:manage_obligations)
  def show?   = can?(:manage_obligations)

  # The target employee must be inside the actor's manage_obligations scope
  # (SEC-M2-4 follow-up); same-business is also enforced by the model.
  # `record` is the class for collection-level checks (e.g. the index's "new" button).
  def create? = can?(:manage_obligations) && (record.is_a?(Class) || manageable_employee?(record.user_id))

  # Changing an obligation — its schedule, auto_deduct, status or installments —
  # is never allowed on one's own debt (segregation of duties, SEC-M2-10); the
  # business owner is the only exception.
  def update?   = manage_others?
  def pause?    = manage_others?
  def resume?   = manage_others?
  def cancel?   = manage_others?
  def postpone? = manage_others?

  # Employees whose obligations the actor may manage: the configured
  # manage_obligations data scope, or — when none is configured — the
  # hierarchy default (EmployeeScope#relation), like the other payroll
  # policies (SEC-M2-11). The actor's own id is included, as in
  # filter_by_data_scope (own obligations stay visible, not changeable).
  def manageable_employee_ids
    configured = user.scope_for(:manage_obligations)
    employees  = configured ? EmployeeScope.new(user).for_scope(configured) : EmployeeScope.new(user).relation
    User.where(business_id: user.business_id)
        .where(id: employees.select(:id)).or(User.where(id: user.id))
        .select(:id)
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      return scope.none unless user.can?(:manage_obligations)

      base = scope.for_business(user.business)
      if (configured = user.scope_for(:manage_obligations))
        filter_by_data_scope(base, configured)
      else
        # No configured scope → hierarchy default, never business-wide (SEC-M2-11).
        managed_ids = EmployeeScope.new(user).relation.select(:id)
        base.where(user_id: managed_ids).or(base.where(user_id: user.id))
      end
    end
  end

  private

  def manage_others?
    can?(:manage_obligations) && (user.owner? || record.user_id != user.id)
  end

  def manageable_employee?(user_id)
    return true if user_id.blank? # the form, or a create that fails validation

    User.where(id: manageable_employee_ids).exists?(id: user_id)
  end
end
