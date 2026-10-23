require "rails_helper"

# Reporting-wide read-only boundary (Batch R; module-boundaries.md §9, §12.1,
# §18 rule 9; next-pilot-selection.md §28). Reporting owns no data: it reads
# every domain and writes none, and no domain depends on it.
#
# Decisions applied (approved 2026-10-20):
# * D-R1 — single-domain Finance & Sales reports under app/services/finance/reports/
#   stay Finance & Sales-owned in place (not moved); only the cross-domain ones
#   are Reporting.
# * D-R2 — Payroll::EntryViewAudit / Salary::ViewAudit calls from Reporting are
#   Infrastructure exceptions (an AuditLog "who saw what" row), allowed only at
#   the call sites listed below; they never permit writing domain data.
#
# Rules:
# 1. Reporting code (controllers, services, views) makes no write call; the only
#    write-like calls are the listed view audits.
# 2. Only Reporting code (and the one Finance & Sales controller that hosts two
#    Reporting actions, with its views) names a Reporting service.
# 3. Every file in the Reporting-adjacent service folders is classified, so a new
#    report is a reviewed ownership decision.
#
# The laundry cost report keeps its own, stricter spec
# (reporting_laundry_cost_summary_boundary_spec.rb, Pilot 11).
module ArchitectureSpecs
  module ReportingReadOnlyBoundary
    module_function

    REPORTING_CONTROLLERS = {
      "app/controllers/dashboard_controller.rb"                => "home dashboard: composes sections from every domain",
      "app/controllers/operations_dashboard_controller.rb"     => "operations dashboard: attendance, payroll and workforce signals",
      "app/controllers/admin/dashboard_controller.rb"          => "admin overview: pending requests and payroll period counts",
      "app/controllers/finance/dashboard_controller.rb"        => "finance executive dashboard (+ PDF export): revenue, profitability, payroll cost",
      "app/controllers/laundry/reports/cost_summary_controller.rb" => "laundry operating-cost report UI (Pilot 11)"
    }.freeze

    REPORTING_SERVICES = {
      "app/services/dashboard/owner_data.rb"                          => "owner dashboard aggregation",
      "app/services/dashboard/area_manager_data.rb"                   => "area manager dashboard aggregation",
      "app/services/finance/dashboard_filters.rb"                     => "finance dashboard period / branch filters",
      "app/services/finance/dashboard/activity_presenter.rb"          => "finance dashboard: recent activity from AuditLog (read)",
      "app/services/finance/dashboard/capabilities.rb"                => "finance dashboard: section gating",
      "app/services/finance/dashboard/insights_generator.rb"          => "finance dashboard: insights over profitability",
      "app/services/finance/dashboard/pdf_renderer.rb"                => "finance dashboard: PDF export rendering",
      "app/services/finance/reports/branch_profitability.rb"          => "cross-domain: revenue (FS) against payroll (AP), consumption (IP), laundry (IP), expenses (FS)",
      "app/services/finance/reports/expense_sources.rb"               => "cross-domain: the cost sources (AP payroll, IP consumption and laundry, WF branch attribution, FS expenses)",
      "app/services/finance/reports/verified_revenue.rb"              => "cross-domain: verified daily-reconciliation revenue for profitability",
      "app/services/finance/reports/laundry_cost_summary.rb"          => "cross-domain laundry operating-cost report (Pilot 11)",
      "app/services/finance/reports/expense_details.rb"               => "cross-domain: per-source breakdown of profitability costs (via ExpenseSources, incl. payroll)",
      "app/services/finance/reports/expense_details_csv_exporter.rb"  => "CSV of the cross-domain expense details"
    }.freeze

    REPORTING_VIEW_DIRS = %w[
      app/views/dashboard/
      app/views/operations_dashboard/
      app/views/admin/dashboard/
      app/views/finance/dashboard/
      app/views/laundry/reports/cost_summary/
    ].freeze

    # Finance::ReportsController hosts two Reporting actions (branch_profitability,
    # expense_details) next to its single-domain Finance & Sales reports. It and
    # its views may name Reporting services and are held to the no-write rule.
    HOST_FILES = {
      "app/controllers/finance/reports_controller.rb" => "FS reports controller hosting the Reporting actions branch_profitability and expense_details"
    }.freeze
    HOST_VIEW_DIRS = %w[app/views/finance/reports/].freeze

    # D-R1: single-domain Finance & Sales reports and the shared report
    # infrastructure stay Finance & Sales-owned in app/services/finance/reports/.
    FINANCE_SALES_REPORT_FILES = {
      "app/services/finance/reports/approval_report.rb"      => "FS: expense approvals",
      "app/services/finance/reports/custody_balances.rb"     => "FS: custody balances",
      "app/services/finance/reports/custody_transactions.rb" => "FS: custody ledger",
      "app/services/finance/reports/expense_summary.rb"      => "FS: expenses by branch / category / type",
      "app/services/finance/reports/expense_report_filters.rb" => "FS report infrastructure (by type / category period + branch filters)",
      "app/services/finance/reports/expense_trend.rb"        => "FS: expense trend",
      "app/services/finance/reports/negative_balances.rb"    => "FS: negative custody balances",
      "app/services/finance/reports/recurring_summary.rb"    => "FS: recurring expenses",
      "app/services/finance/reports/shared_allocation.rb"    => "FS: shared expense allocation",
      "app/services/finance/reports/column.rb"               => "FS report infrastructure (CSV columns), also used by Reporting",
      "app/services/finance/reports/table.rb"                => "FS report infrastructure (tables), also used by Reporting",
      "app/services/finance/reports/csv_exporter.rb"         => "FS report infrastructure (CSV), also used by Reporting",
      "app/services/finance/reports/period_resolver.rb"      => "FS report infrastructure (period parameters), also used by Reporting"
    }.freeze

    # Single-domain services located in a Reporting-adjacent folder, owned by
    # their domain in place (the D-R1 principle; §18 rule 9).
    OTHER_DOMAIN_FILES = {
      "app/services/dashboard/birthdays.rb" => "Workforce: today's employee birthdays (users + their branch membership) " \
                                               "and the once-a-day celebration marker in Rails.cache; also used by " \
                                               "BirthdayCelebrationsController"
    }.freeze

    CLASSIFIED_FOLDERS = %w[app/services/dashboard/ app/services/finance/dashboard/ app/services/finance/reports/].freeze

    # Reporting's own service constants (rule 2). Dashboard::Birthdays is not one.
    REPORTING_CONSTANT = /
      \bDashboard::(?:OwnerData|AreaManagerData)\b
      | \bFinance::Dashboard::[A-Z]\w*
      | \bDashboardFilters\b
      | \b(?:BranchProfitability|ExpenseSources|VerifiedRevenue|LaundryCostSummary|ExpenseDetails(?:CsvExporter)?)\b
    /x

    WRITE_CALL = /\.(?:create|update|update_all|update_columns?|update_attribute|save|destroy|destroy_all|delete|delete_all|
                    insert|insert_all|upsert|upsert_all|build|find_or_create_by|create_or_find_by|increment|decrement|toggle|
                    touch|lock|with_lock|perform_later|perform_now|deliver_later|deliver_now)!?(?=[(\s]|$)
                  | \blog_audit\b | \btransaction\b/x

    # D-R2: the view audits, and exactly where Reporting may call them.
    VIEW_AUDIT_CALL = /\b(?:Payroll::EntryViewAudit|Salary::ViewAudit)\.record\(/
    ALLOWED_VIEW_AUDITS = {
      "app/controllers/dashboard_controller.rb"         => 1, # dashboard_latest_payslip
      "app/controllers/finance/reports_controller.rb"   => 2  # finance_expense_details (HTML, CSV)
    }.freeze
    VIEW_AUDIT_FILES = %w[app/services/payroll/entry_view_audit.rb app/services/salary/view_audit.rb].freeze

    def reporting_files
      files = REPORTING_CONTROLLERS.keys + REPORTING_SERVICES.keys + HOST_FILES.keys
      files + source_files.select { |path| (REPORTING_VIEW_DIRS + HOST_VIEW_DIRS).any? { |dir| path.start_with?(dir) } }
    end

    def may_name_reporting?(path) = reporting_files.include?(path)

    def source_files(root = "{app,lib}")
      Dir.glob(Rails.root.join("#{root}/**/*.{rb,erb,rake}")).map { |f| f.delete_prefix("#{Rails.root}/") }.sort
    end

    # Code only: full-line comments and ERB comments are dropped, string
    # contents blanked and trailing comments removed, so a word in a comment or
    # a message is not a dependency.
    def code_lines(path)
      source = File.read(Rails.root.join(path))
      source = source.gsub(/<%#.*?%>/m) { |c| "\n" * c.count("\n") } if path.end_with?(".erb")
      source.each_line.with_index(1)
            .reject { |line, _| line.lstrip.start_with?("#") }
            .map do |line, number|
              code = line.gsub(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/, '""').sub(/\s#\s.*$/, "")
              [ code, number ]
            end
    end

    def matches_in(path, pattern)
      code_lines(path).filter_map { |line, number| "#{path}:#{number}: #{line.strip}" if line.match?(pattern) }
    end
  end
end

RSpec.describe "Architecture: Reporting is read-only and nothing depends on it" do
  boundary = ArchitectureSpecs::ReportingReadOnlyBoundary

  it "classifies every file in the Reporting-adjacent service folders (no unowned report)" do
    classified = boundary::REPORTING_SERVICES.keys + boundary::FINANCE_SALES_REPORT_FILES.keys + boundary::OTHER_DOMAIN_FILES.keys
    present    = boundary.source_files.select { |path| boundary::CLASSIFIED_FOLDERS.any? { |dir| path.start_with?(dir) } }

    stale      = classified.reject { |path| File.exist?(Rails.root.join(path)) }

    expect(present - classified).to be_empty, "Classify (Reporting, Finance & Sales or another domain): #{(present - classified).join(', ')}"
    expect(stale).to be_empty, "Remove stale entries: #{stale.join(', ')}"
  end

  it "keeps every listed Reporting / host file and directory present" do
    files = boundary::REPORTING_CONTROLLERS.keys + boundary::HOST_FILES.keys + boundary::VIEW_AUDIT_FILES
    missing = files.reject { |path| File.exist?(Rails.root.join(path)) } +
              (boundary::REPORTING_VIEW_DIRS + boundary::HOST_VIEW_DIRS).reject { |dir| Dir.exist?(Rails.root.join(dir)) }
    expect(missing).to be_empty, "Remove or fix: #{missing.join(', ')}"
  end

  it "Reporting code makes no write call (rule 1)" do
    writes = boundary.reporting_files.flat_map { |path| boundary.matches_in(path, boundary::WRITE_CALL) }
    expect(writes).to be_empty, "Reporting must not write:\n#{writes.join("\n")}"
  end

  it "calls the view audits only at the classified sites (D-R2)" do
    calls = boundary.reporting_files.to_h { |path| [ path, boundary.matches_in(path, boundary::VIEW_AUDIT_CALL).size ] }
                    .reject { |_, count| count.zero? }
    expect(calls).to eq(boundary::ALLOWED_VIEW_AUDITS)
  end

  it "the view audits write only an AuditLog row (D-R2: no domain data)" do
    boundary::VIEW_AUDIT_FILES.each do |path|
      writes = boundary.matches_in(path, boundary::WRITE_CALL)
      expect(writes).to all(match(/\blog_audit\(/)), "#{path} may only call log_audit:\n#{writes.join("\n")}"
      expect(writes.size).to eq(1)
    end
    expect([ Payroll::EntryViewAudit, Salary::ViewAudit ]).to all(be < AuditLoggable)
  end

  it "no code outside Reporting names a Reporting service (rule 2)" do
    outside = boundary.source_files.reject { |path| boundary.may_name_reporting?(path) }
                      .flat_map { |path| boundary.matches_in(path, boundary::REPORTING_CONSTANT) }
    expect(outside).to be_empty, <<~MSG
      Nothing depends on Reporting (module-boundaries.md §12.1). These files name a Reporting service:
      #{outside.join("\n")}
    MSG
  end

  describe "self-tests" do
    it "matches Reporting constants and not Finance & Sales reports, Birthdays or controllers" do
      [
        "Finance::Reports::BranchProfitability.new(b)", "Finance::Reports::ExpenseSources.new(b, year: y, month: m)",
        "Finance::Dashboard::InsightsGenerator.new", "Dashboard::OwnerData.new(u)", "ExpenseDetailsCsvExporter.new(r)"
      ].each { |code| expect(code).to match(boundary::REPORTING_CONSTANT), code }
      [
        "Finance::Reports::ExpenseSummary.new(b)", "Finance::Reports::CsvExporter.new(t)", "Dashboard::Birthdays.team(u)",
        "Finance::DashboardController", "expense_details_path"
      ].each { |code| expect(code).not_to match(boundary::REPORTING_CONSTANT), code }
    end

    it "flags a Reporting service named by a Finance & Sales report (planted)" do
      path = "app/services/finance/reports/expense_trend.rb"
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(Rails.root.join(path)).and_return("sources = ExpenseSources.new(b, year: y, month: m)\n")

      expect(boundary.may_name_reporting?(path)).to be(false)
      expect(boundary.matches_in(path, boundary::REPORTING_CONSTANT)).not_to be_empty
    end

    it "flags a write and an extra view audit planted in Reporting code" do
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(Rails.root.join("app/services/dashboard/owner_data.rb"))
        .and_return("PayrollEntry.where(id: ids).update_all(net_salary: 0)\nPayroll::EntryViewAudit.record(actor: u, entries: e, source: s)\n")

      expect(boundary.matches_in("app/services/dashboard/owner_data.rb", boundary::WRITE_CALL)).not_to be_empty
      expect(boundary.matches_in("app/services/dashboard/owner_data.rb", boundary::VIEW_AUDIT_CALL).size).to eq(1)
    end

    it "ignores Reporting names in comments and strings" do
      path = "app/services/hypothetical_comment.rb"
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(Rails.root.join(path))
        .and_return("# BranchProfitability is Reporting\nmsg = \"see ExpenseSources\" # VerifiedRevenue\n")

      expect(boundary.matches_in(path, boundary::REPORTING_CONSTANT)).to be_empty
    end
  end
end
