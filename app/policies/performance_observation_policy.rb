class PerformanceObservationPolicy < ApplicationPolicy
  def index?  = can?(:view_notes) || can?(:create_observations)
  def show?   = index? && same_business?
  def create? = can?(:create_observations)
  def new?    = create?

  # Observations are an audit trail: only the author (or the owner) may revise
  # or remove one, and only with the observation permission.
  def update?  = can?(:create_observations) && (record.observed_by_id == user.id || owner?)
  def destroy? = update?

  class Scope < ApplicationPolicy::Scope
    def resolve
      base = scope.for_business(user.business)

      configured = user.scope_for(:view_notes) || user.scope_for(:create_observations)
      if user.owner? || configured == "business"
        base
      elsif configured
        filter_by_data_scope(base, configured, user_id_column: :employee_id)
      else
        managed_ids = EmployeeScope.new(user).relation.select(:id)
        base.where(employee_id: user.id).or(base.where(employee_id: managed_ids))
      end
    end
  end
end
