module Payroll
  # Records that payroll-entry amounts were shown — a payslip, or per-employee
  # payroll rows (HTML, CSV or API): one "view_payroll_entry" AuditLog per
  # request, written after the request was authorized and the entries were
  # loaded, only when at least one entry is shown. Distinct from "view_salary"
  # (Salary::ViewAudit): a payroll entry is the period's computed pay, not the
  # salary profile.
  #
  # The auditable is the entry when one is shown, else the period when they all
  # belong to one, else the business. Metadata holds where they were shown, the
  # entry and employee ids and whether they were all the actor's own — never
  # amounts.
  #
  # Like every log_audit call, a failed write is logged and swallowed: the view
  # still succeeds, so this record is not a guarantee (AuditLoggable).
  class EntryViewAudit
    include AuditLoggable

    ACTION  = "view_payroll_entry".freeze
    SOURCES = %w[
      payslip period_entries my_payslips dashboard_latest_payslip
      payroll_dashboard_top_employees branch_payroll_summary bank_transfer_export
      finance_expense_details finance_expense_details_csv
      api_payroll_entries api_payroll_entry api_payroll_entry_update api_payroll_period
      api_payroll_report_summary api_payroll_report_export
    ].freeze

    def self.record(actor:, entries:, source:)
      new.record(actor: actor, entries: entries, source: source)
    end

    def record(actor:, entries:, source:)
      raise ArgumentError, "unknown payroll entry view source: #{source}" unless SOURCES.include?(source)

      entries = Array(entries).compact
      return if entries.empty?

      employee_ids = entries.map(&:user_id).uniq
      log_audit(actor: actor, auditable: auditable_for(entries, actor), action: ACTION,
                metadata: { source: source, payroll_entry_ids: entries.map(&:id), employee_ids: employee_ids,
                            self_view: employee_ids == [ actor.id ] })
    end

    private

    def auditable_for(entries, actor)
      return entries.first if entries.one?

      period_ids = entries.map(&:payroll_period_id).uniq
      period_ids.one? ? PayrollPeriod.find(period_ids.first) : actor.business
    end
  end
end
