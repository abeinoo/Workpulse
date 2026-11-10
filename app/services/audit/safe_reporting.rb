module Audit
  # Logging and error reporting for the durable audit path (R3.1; plan §19.13
  # T-R31-15). A database exception's message can quote row values (PostgreSQL's
  # "DETAIL: Failing row contains (…)"), so the exception itself is never handed
  # to Rails.error: the report carries a SanitizedError naming only the original
  # class, and a context of ids, counters and schema identifiers. Logging or
  # reporting never raises into the caller. The full-payload log of D28 is the
  # one exception and lives in Audit::DurableEntry#log_last_resort only.
  #
  # The including class also includes AuditLoggable (audit_error_details).
  module SafeReporting
    SOURCE = "pending_audit_event.work_pulse".freeze

    # Stands in for the real exception in error reports: its message is the
    # original class name, nothing else.
    class SanitizedError < StandardError; end

    private

    def log_safely(message)
      Rails.logger.error(message)
    rescue StandardError
      nil
    end

    def report_safely(error, severity:, context:)
      details = error_identifiers(error)
      Rails.error.report(SanitizedError.new(error.class.name), handled: true, severity: severity, source: SOURCE,
                                                                context: context.merge(details))
    rescue StandardError
      nil
    end

    def error_identifiers(error)
      { error_class: error.class.name, **audit_error_details(error) }
    rescue StandardError
      { error_class: error.class.name }
    end
  end
end
