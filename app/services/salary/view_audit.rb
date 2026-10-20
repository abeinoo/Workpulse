module Salary
  # Records that salary data was shown: one "view_salary" AuditLog row per
  # request that returned at least one salary profile, written after the
  # request was authorized and the profiles were loaded. The auditable is the
  # employee whose salary was shown; metadata holds where it was shown and the
  # profile ids — never amounts or other profile contents.
  #
  # request_advance_limit: the advance limit shown when submitting a request on
  # behalf of another employee — a fixed percentage of a monthly salary, so the
  # salary itself can be read off it.
  #
  # Like every log_audit call, a failed write is logged and swallowed: it never
  # aborts the request (AuditLoggable).
  class ViewAudit
    include AuditLoggable

    ACTION  = "view_salary".freeze
    SOURCES = %w[
      admin_employee_page admin_salary_profile_edit
      api_salary_profiles api_salary_profile api_salary_profile_update
      request_advance_limit
    ].freeze

    def self.record(actor:, employee:, profiles:, source:)
      new.record(actor: actor, employee: employee, profiles: profiles, source: source)
    end

    def record(actor:, employee:, profiles:, source:)
      raise ArgumentError, "unknown salary view source: #{source}" unless SOURCES.include?(source)

      profile_ids = Array(profiles).compact.map(&:id)
      return if profile_ids.empty?

      log_audit(actor: actor, auditable: employee, action: ACTION,
                metadata: { source: source, self_view: actor.id == employee.id, salary_profile_ids: profile_ids })
    end
  end
end
