module AuditLoggable
  extend ActiveSupport::Concern

  # Emit a structured audit log entry. Failures are swallowed and logged to
  # Rails.logger — an audit write must never abort the primary operation.
  #
  # actor:     User performing the action (required)
  # auditable: The AR record being acted upon (required)
  # action:    Short verb string: "approve", "reject", "pay", "deactivate", …
  # changes:   { field: [before, after] } — optional before/after diff
  # metadata:  Any extra context (reason, notes, …)
  def log_audit(actor:, auditable:, action:, changes: {}, metadata: {})
    AuditLog.create!(
      actor:         actor,
      business:      actor.business,
      auditable:     auditable,
      action:        action.to_s,
      changes_json:  changes,
      metadata:      metadata
    )
  rescue => e
    Rails.logger.error("[AuditLog] Failed to write audit entry: #{e.class}: #{e.message}")
    nil
  end
end
