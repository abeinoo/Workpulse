class PayrollEntryPolicy < ApplicationPolicy
  def index?  = true  # scope handles isolation; employees see only their own finalized/paid entries
  def show?   = can?(:view_payroll) || owner? || manages_area? || manages_branch? || own_entry? || managed_entry?
  def update? = can?(:manage_payroll) || owner?

  class Scope < ApplicationPolicy::Scope
    def resolve
      business_scoped = scope.joins(:payroll_period)
                             .where(payroll_periods: { business_id: user.business_id })

      if user.owner?
        business_scoped
      elsif user.can?(:view_payroll)
        if (configured = user.scope_for(:view_payroll))
          # Explicit override — honour the configured scope exactly.
          filter_by_data_scope(business_scoped, configured)
        else
          # No override — fall back to canonical management hierarchy.
          business_scoped.where(user_id: EmployeeScope.new(user).relation.select(:id))
        end
      elsif user.management_access?
        business_scoped.where(user_id: EmployeeScope.new(user).relation.select(:id))
      else
        scope.joins(:payroll_period)
             .where(user_id: user.id)
             .where(payroll_periods: { status: %w[finalized paid] })
      end
    end
  end

  private

  def own_entry?
    record.user_id == user.id
  end

  def managed_entry?
    EmployeeScope.new(user).includes?(record.user_id)
  end
end
