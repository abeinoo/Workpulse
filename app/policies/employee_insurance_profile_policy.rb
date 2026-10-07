class EmployeeInsuranceProfilePolicy < ApplicationPolicy
  def show?    = viewable?
  # The employee must be inside the actor's insurance scope — the same employees
  # Scope#resolve shows (SEC-P8-2).
  def create?  = can?(:manage_employee_insurance) && employee_in_scope?
  def update?  = create?
  def destroy? = false

  # Whether the employer contribution amount may be shown to this user —
  # confidential company cost data, never shown on a self-view.
  def view_employer_contribution?
    can?(:manage_employee_insurance)
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.can?(:manage_employee_insurance) || user.can?(:view_employee_insurance)
        base       = scope.joins(:user).where(users: { business_id: user.business_id })
        configured = user.scope_for(:manage_employee_insurance) || user.scope_for(:view_employee_insurance)

        if configured
          filter_by_data_scope(base, configured, user_id_column: :user_id)
        else
          managed_ids = EmployeeScope.new(user).relation.select(:id)
          base.where(user_id: user.id).or(base.where(user_id: managed_ids))
        end
      else
        scope.where(user_id: user.id)
      end
    end
  end

  private

  def viewable?
    can?(:manage_employee_insurance) || can?(:view_employee_insurance) || own_record?
  end

  def own_record?
    record.user_id == user.id
  end

  # Mirrors Scope#resolve: the configured manage_employee_insurance scope, else
  # the view_employee_insurance scope, else the manager hierarchy; one's own
  # profile is always included.
  def employee_in_scope?
    return true if record.is_a?(Class) || own_record?

    EmployeeScope.new(user).for_permissions(:manage_employee_insurance, :view_employee_insurance)
                 .where(business_id: user.business_id)
                 .exists?(id: record.user_id)
  end
end
