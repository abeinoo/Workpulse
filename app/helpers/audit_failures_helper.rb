module AuditFailuresHelper
  STATUS_BADGES = { resolved: "badge-success", escalated: "badge-danger", pending: "badge-warning" }.freeze

  # Sidebar badge (D32): unresolved escalated events of the current business,
  # counted through the policy scope (zero without monitor_audit_failures).
  # One count per request.
  def audit_failure_escalation_count
    return 0 unless user_signed_in?

    @audit_failure_escalation_count ||=
      PendingAuditEventPolicy::Scope.new(current_user, PendingAuditEvent).resolve.escalated_unresolved.count
  end

  def audit_failure_status_badge(event)
    tag.span(t("audit_failures.statuses.#{event.status}"), class: "badge #{STATUS_BADGES.fetch(event.status)}")
  end

  # Schema identifiers or attribute names only (never values), as stored.
  def audit_failure_error_details(details)
    return "—" if details.blank?

    details.map { |key, value| "#{key}: #{Array(value).join(', ')}" }.join(" · ")
  end

  # The default time format: it includes the year, since events are kept
  # indefinitely (L34).
  def audit_failure_time(time)
    time ? l(time) : "—"
  end
end
