class PayrollEntryPolicy < ApplicationPolicy
  def index?  = true  # scope handles isolation; employees see only their own finalized/paid entries
  def show?   = can?(:view_payroll) || own_entry?
  # Editing entry-level fields is a payroll-rebuild concern: it requires the
  # same authority as regenerating the period's calculations.
  def update? = can?(:regenerate_payroll)

  # Overriding payable overtime — dedicated permission, only while the period is
  # still reviewable (draft / under_review). Locked periods are immutable.
  def override_overtime?
    can?(:manage_payroll_overrides) &&
      record.payroll_period&.business_id == user.business_id &&
      record.payroll_period&.reviewable?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve
      business_scoped = scope.joins(:payroll_period)
                             .where(payroll_periods: { business_id: user.business_id })

      if user.can?(:view_payroll)
        if (configured = user.scope_for(:view_payroll))
          filter_by_data_scope(business_scoped, configured)
        else
          business_scoped.where(user_id: EmployeeScope.new(user).relation.select(:id))
        end
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
end
