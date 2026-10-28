module AuditLoggable
  extend ActiveSupport::Concern

  # Raised by #log_audit! when the audit entry could not be written; the
  # original error is kept as #cause. An ActiveRecordError, so a caller that
  # already turns ActiveRecord errors into a failed Result handles it as one.
  class AuditWriteFailed < ActiveRecord::ActiveRecordError; end

  # Failures of the caller's connection or transaction rather than of the
  # audit entry itself: never treated as an audit-only failure (see
  # #unrecoverable_audit_error?).
  UNRECOVERABLE_AUDIT_ERRORS = [
    ActiveRecord::ConnectionNotEstablished,
    ActiveRecord::ConnectionFailed,
    ActiveRecord::AdapterTimeout,
    ActiveRecord::SerializationFailure
  ].freeze

  # Emit a structured audit log entry. Returns the AuditLog, or nil when the
  # entry alone could not be written (fail-open): the failure is logged and
  # reported through Rails.error, and the primary operation continues.
  #
  # The entry is written in its own savepoint, so a database error on the
  # audit insert rolls back only that insert. Without it PostgreSQL aborts the
  # caller's whole transaction, and a COMMIT issued afterwards silently rolls
  # everything back while the caller reports success (BUG-003).
  #
  # A lost connection, or a caller transaction that was already aborted
  # before the audit write (or is not usable after it), is re-raised: the
  # primary operation can no longer complete, and it must fail visibly rather
  # than be reported as an audit failure.
  #
  # actor:     User performing the action (required)
  # auditable: The AR record being acted upon (required)
  # action:    Short verb string: "approve", "reject", "pay", "deactivate", …
  # changes:   { field: [before, after] } — optional before/after diff
  # metadata:  Any extra context (reason, notes, …)
  def log_audit(actor:, auditable:, action:, changes: {}, metadata: {})
    write_audit_log!(actor: actor, auditable: auditable, action: action, changes: changes, metadata: metadata)
  rescue AuditWriteFailed
    nil
  end

  # Fail-closed variant for operations whose audit entry must exist: same
  # write and the same single report, then raises AuditWriteFailed so the
  # caller's transaction rolls back.
  def log_audit!(actor:, auditable:, action:, changes: {}, metadata: {})
    write_audit_log!(actor: actor, auditable: auditable, action: action, changes: changes, metadata: metadata)
  end

  private

  def write_audit_log!(actor:, auditable:, action:, changes:, metadata:)
    AuditLog.transaction(requires_new: true) do
      AuditLog.create!(
        actor:         actor,
        business:      actor.business,
        auditable:     auditable,
        action:        action.to_s,
        changes_json:  changes,
        metadata:      metadata
      )
    end
  rescue StandardError => e
    # Audit-only only when the caller's transaction is demonstrably still
    # usable — e.g. not when rolling back to the savepoint itself failed.
    raise if unrecoverable_audit_error?(e) || !audit_transaction_usable?

    report_audit_failure(e, actor: actor, auditable: auditable, action: action, changes: changes, metadata: metadata)
    raise AuditWriteFailed, "audit entry #{action} could not be written (#{e.class})"
  end

  # A PG::InFailedSqlTransaction (wrapped in StatementInvalid) means the
  # caller's transaction was aborted before the audit write: the savepoint
  # itself could not be created.
  def unrecoverable_audit_error?(error)
    audit_error_chain(error).any? do |cause|
      UNRECOVERABLE_AUDIT_ERRORS.any? { |klass| cause.is_a?(klass) } ||
        cause.is_a?(PG::InFailedSqlTransaction) || cause.is_a?(PG::ConnectionBad)
    end
  end

  # Runs only after a failed audit write.
  def audit_transaction_usable?
    AuditLog.with_connection { |connection| connection.select_value("SELECT 1") }.to_i == 1
  rescue StandardError
    false
  end

  def audit_error_chain(error)
    chain = []
    while error && chain.size < 5
      chain << error
      error = error.cause
    end
    chain
  end

  # Names and ids only: change and metadata values can hold amounts, notes or
  # personal data, so only their keys are reported. The error message is left
  # out too — PostgreSQL's DETAIL line (and some first lines) quote row values.
  def report_audit_failure(error, actor:, auditable:, action:, changes:, metadata:)
    context = {
      action:         action.to_s,
      auditable_type: (auditable.class.name unless auditable.nil?),
      auditable_id:   auditable.try(:id),
      actor_id:       actor.try(:id),
      business_id:    actor.try(:business_id),
      change_keys:    audit_keys(changes),
      metadata_keys:  audit_keys(metadata),
      error_class:    error.class.name,
      **audit_error_details(error)
    }
    Rails.logger.error("[AuditLog] Failed to write audit entry #{context.to_json}")
    Rails.error.report(error, handled: true, severity: :error, context: context, source: "audit_log.work_pulse")
  rescue StandardError => reporting_error
    # Reporting must never replace the audit failure being reported.
    begin
      Rails.logger.error("[AuditLog] Failed to report an audit write failure (#{error.class}): #{reporting_error.class}")
    rescue StandardError
      nil
    end
  end

  def audit_keys(hash)
    hash.respond_to?(:keys) ? hash.keys.map(&:to_s) : []
  end

  # Schema identifiers only (SQLSTATE, table, column, constraint) or the names
  # of invalid attributes — never a message that could quote a value.
  def audit_error_details(error)
    pg_error = audit_error_chain(error).find { |cause| cause.is_a?(PG::Error) }
    if (result = pg_error&.result)
      {
        sqlstate:   result.error_field(PG::PG_DIAG_SQLSTATE),
        table:      result.error_field(PG::PG_DIAG_TABLE_NAME),
        column:     result.error_field(PG::PG_DIAG_COLUMN_NAME),
        constraint: result.error_field(PG::PG_DIAG_CONSTRAINT_NAME)
      }.compact
    elsif error.is_a?(ActiveRecord::RecordInvalid) && error.record
      { invalid_attributes: error.record.errors.attribute_names.map(&:to_s) }
    else
      {}
    end
  end
end
