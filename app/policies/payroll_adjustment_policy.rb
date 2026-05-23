class PayrollAdjustmentPolicy < ApplicationPolicy
  def index?
    same_business? && (can?(:view_payroll) || owner? || manages_area? || manages_branch? || direct_manager?)
  end

  def new?
    same_business? && (owner? || manages_area? || manages_branch? || direct_manager?)
  end

  def create?  = can_manage_adjustment?
  def approve? = can_review?
  def reject?  = can_review?

  def destroy?
    return false unless record.pending_review?
    return false unless same_business?

    owner? || record.created_by_id == user.id
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      business_scoped = scope.where(business: user.business)

      if user.owner?
        business_scoped
      elsif user.can?(:view_payroll)
        if (configured = user.scope_for(:view_payroll))
          filter_by_data_scope(business_scoped, configured)
        else
          business_scoped.where(user_id: EmployeeScope.new(user).relation.select(:id))
        end
      elsif user.management_access?
        business_scoped.where(user_id: EmployeeScope.new(user).relation.select(:id))
      else
        business_scoped.where(user_id: user.id)
      end
    end
  end

  private

  def can_manage_adjustment?
    return false unless same_business?
    return true if owner?
    return false unless record.user

    # Permission-holders (e.g. Finance) can adjust for any same-business employee.
    return true if can?(:manage_adjustments)

    # Relationship-based managers are scoped to their managed employees only.
    return false unless manages_area? || manages_branch? || direct_manager?

    employee_under_management?
  end

  def can_review?
    return false unless same_business?
    can?(:approve_adjustments) || owner?
  end

  def employee_under_management?
    return false unless record.user
    EmployeeScope.new(user).includes?(record.user_id)
  end

  def direct_manager?
    user.managed_employees.exists?
  end
end
