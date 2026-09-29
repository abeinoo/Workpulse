module EmployeeDataRequestsHelper
  EDR_STATUS_BADGES = {
    "pending_review"    => "badge-warning",
    "changes_requested" => "badge-accent",
    "approved"          => "badge-success",
    "rejected"          => "badge-danger"
  }.freeze

  def edr_status_badge(request)
    tag.span(t("employee_data_requests.statuses.#{request.status}"),
             class: "badge #{EDR_STATUS_BADGES.fetch(request.status, 'badge-neutral')}")
  end
end
