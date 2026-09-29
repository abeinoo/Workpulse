# Employee Add Requests (طلبات إضافة موظف) carry sensitive personal data
# (national ID, ID card photos). Every action has its own explicit permission
# (PermissionRole group :employee_onboarding) — none is implied by another, and
# none grants anything outside this workflow:
#
#   create_employee_requests   — submit; resubmit own after changes requested
#   view_employee_requests     — see requests you submitted
#   view_all_employee_requests — see requests submitted by users in your scope
#   review_employee_requests   — reviewer mode: correct data, ID photos,
#                                reviewer-only verification details
#   approve_employee_requests  — approve (creates the employee)
#   reject_employee_requests   — reject
#   request_employee_changes   — send back to the requester
#
# Scope: a request has no branch, so visibility follows its SUBMITTER through
# the standard employee data scope of view_all_employee_requests
# (self / branch / area / business; unset → the manager hierarchy), exactly
# like other user-owned records. The owner resolves to business-wide.
#
# Nobody reviews or decides on a request they submitted — owner included.
class EmployeeDataRequestPolicy < ApplicationPolicy
  # The feature (list page + the sidebar entry under "Employees") is reachable
  # with ANY Employee Add Request permission; what the list contains is still
  # limited by Scope, and each action by its own permission below.
  def index?  = PermissionRole::PERMISSION_GROUPS[:employee_onboarding].any? { |p| can?(p) }
  def create? = can?(:create_employee_requests)
  def show?   = own_visible? || in_review_scope?

  # Class-level: whether the list shows other submitters' requests, and whether
  # its rows offer reviewer mode (rows are already policy-scoped).
  def view_all?   = can?(:view_all_employee_requests)
  def review_any? = can?(:review_employee_requests) && view_all?

  # ID photos: the requester's own upload, or a reviewer in reviewer mode.
  def document? = own_visible? || review?

  # Resubmission: only the requester, only after changes were requested.
  def update? = own_visible? && can?(:create_employee_requests) && record.changes_requested?

  # Reviewer mode (read side): verification checks, submitted-vs-corrected
  # comparison, documents. Status-independent so it stays after the decision.
  def review?         = can?(:review_employee_requests) && in_review_scope? && !own_submission?
  def review_details? = review?

  # Reviewer mode (write side): correcting the data while pending.
  def correct? = review? && record.pending_review?

  def approve?         = decision?(:approve_employee_requests)
  def reject?          = decision?(:reject_employee_requests)
  def request_changes? = decision?(:request_employee_changes)
  def decide?          = approve? || reject? || request_changes?

  class Scope < ApplicationPolicy::Scope
    def resolve
      base = scope.where(business_id: user.business_id)

      if user.can?(:view_all_employee_requests)
        configured = user.scope_for(:view_all_employee_requests)
        if configured
          filter_by_data_scope(base, configured, user_id_column: :submitted_by_id)
        else
          base.where(submitted_by_id: user.id)
              .or(base.where(submitted_by_id: EmployeeScope.new(user).relation.select(:id)))
        end
      elsif user.can?(:view_employee_requests)
        base.where(submitted_by_id: user.id)
      else
        scope.none
      end
    end
  end

  private

  def request? = record.is_a?(EmployeeDataRequest)

  def own_submission? = request? && record.submitted_by_id == user.id

  def own_visible?
    own_submission? && same_business? && can?(:view_employee_requests)
  end

  def in_review_scope?
    return false unless request? && same_business? && can?(:view_all_employee_requests)

    Scope.new(user, EmployeeDataRequest).resolve.exists?(id: record.id)
  end

  def decision?(permission)
    request? && record.pending_review? && can?(permission) && in_review_scope? && !own_submission?
  end
end
