class PerformanceReviewPolicy < ApplicationPolicy
  def index? = true # scope handles isolation (managers see scope, employees see own)

  # Managers with view_monthly_reviews see all reviews in their scope.
  # An employee may always see their OWN finalized reviews regardless of permissions.
  def show?
    return true if can?(:view_monthly_reviews) && same_business?
    own_finalized_review?
  end

  def create? = can?(:manage_reviews)
  def new?    = create?

  # Finalized reviews are locked. Edits require the review permission.
  def update? = can?(:manage_reviews) && !record.finalized?
  def edit?   = update?

  def submit?   = can?(:manage_reviews) && record.draft?
  def finalize? = can?(:finalize_reviews) && !record.finalized?

  class Scope < ApplicationPolicy::Scope
    def resolve
      base = scope.for_business(user.business)

      if user.can?(:view_monthly_reviews)
        configured = user.scope_for(:view_monthly_reviews)
        if user.owner? || configured == "business"
          base
        elsif configured
          filter_by_data_scope(base, configured, user_id_column: :employee_id)
        else
          managed_ids = EmployeeScope.new(user).relation.select(:id)
          base.where(employee_id: user.id).or(base.where(employee_id: managed_ids))
        end
      else
        # Plain employee: only their own finalized reviews.
        base.where(employee_id: user.id, status: "finalized")
      end
    end
  end

  private

  def own_finalized_review?
    record.employee_id == user.id && record.finalized?
  end
end
