require "rails_helper"

# Boundary enforcement for Milestone 2 Pilot 2 — Employee Obligations
# (Attendance & Payroll, M6; see docs/architecture/next-pilot-selection.md,
# Milestone 2, Pilot 2 M0).
#
# EmployeeObligation, ObligationDeduction, ObligationPostponement and the
# Payroll::Obligation{Editor,InstallmentPostponer,Deductor} services are owned
# by Attendance & Payroll. M0 found no cross-domain writes, no circular
# dependency and no cross-domain business caller, so there is NO boundary
# object: Attendance & Payroll code (including the payroll core that deducts
# obligations) uses them directly, and other domains must not reach their
# internals (the classes, the services, or the `employee_obligations` /
# `obligation_deductions` / `obligation_postponements` collections and tables).
#
# Not guarded: the payroll line-item type "obligation_deduction" and its
# predicate obligation_deduction? (payroll core), the PayrollEntry column
# obligations_deducted, EmployeeObligationPolicy, route helpers
# (admin_employee_obligations_path …), the manage_obligations permission, and
# config/ (routes, locales), as in the other boundary specs.
#
# This spec fails on any NEW direct reference outside the allow-list below.
# Adding to the allow-list is an architectural decision: give the reason.
module ArchitectureSpecs
  module AttendancePayrollObligationBoundary
    module_function

    FORBIDDEN = /
      \bEmployeeObligation\b                 # the models and their class methods (not EmployeeObligationPolicy)
      | \bObligationDeduction\b
      | \bObligationPostponement\b
      | \bemployee_obligations\b              # collections and tables
      | \bobligation_deductions\b
      | \bobligation_postponements\b
      | \bObligation(?:Editor|InstallmentPostponer|Deductor)\b # Payroll:: obligation services
    /x

    # Attendance & Payroll-owned code (module-boundaries.md §6).
    ATTENDANCE_PAYROLL_FILES = {
      "app/models/employee_obligation.rb"                        => "the model itself (moves to app/models/attendance_payroll/ in M7)",
      "app/models/obligation_deduction.rb"                       => "the model itself (moves to app/models/attendance_payroll/ in M7)",
      "app/models/obligation_postponement.rb"                    => "the model itself (moves to app/models/attendance_payroll/ in M7)",
      "app/controllers/admin/employee_obligations_controller.rb" => "AP obligation administration (EmployeeObligationPolicy)",
      "app/services/payroll/obligation_editor.rb"                => "AP obligation service",
      "app/services/payroll/obligation_installment_postponer.rb" => "AP obligation service",
      "app/services/payroll/obligation_deductor.rb"              => "AP obligation service",
      # Payroll core consuming obligation results — internal to Attendance & Payroll, not an external dependency.
      "app/models/payroll_period.rb"                             => "AP payroll core: has_many :obligation_deductions",
      "app/services/payroll/entry_calculator.rb"                 => "AP payroll core: deducts via ObligationDeductor",
      "app/services/payroll/entry_recalculator.rb"               => "AP payroll core: rebuilds a user's obligation-deduction snapshots",
      "app/services/payroll/period_generator.rb"                 => "AP payroll core: clears a period's obligation-deduction snapshots on regeneration"
    }.freeze

    ATTENDANCE_PAYROLL_DIRS = [
      "app/views/admin/employee_obligations/"                    # AP obligation administration screens
    ].freeze

    # Cross-domain exceptions documented in the Pilot 2 M0 classification (class C / G).
    EXCEPTION_FILES = {
      "app/models/business.rb"              => "Organization & Access inverse association: has_many :employee_obligations",
      "app/models/user.rb"                  => "Organization & Access inverse association: has_many :employee_obligations",
      "app/views/admin/users/show.html.erb" => "Workforce employee-page obligations card (documented read; visibility is the deferred SEC-M2-5 / Q-M2-5)",
      "app/views/layouts/_sidebar.html.erb" => "UI shell: obligations nav entry (admin path and label key)"
    }.freeze

    def allowed_files = ATTENDANCE_PAYROLL_FILES.merge(EXCEPTION_FILES)

    def source_files
      Dir.glob(Rails.root.join("{app,lib}/**/*.{rb,erb,rake}")).map { |f| f.delete_prefix("#{Rails.root}/") }.sort
    end

    # Full-line Ruby comments and ERB comments (including multi-line) are ignored.
    def code_lines(path)
      source = File.read(Rails.root.join(path))
      source = source.gsub(/<%#.*?%>/m) { |c| "\n" * c.count("\n") } if path.end_with?(".erb")
      source.each_line.with_index(1).reject { |line, _| line.lstrip.start_with?("#") }
    end

    def violations_in(path)
      code_lines(path).filter_map { |line, number| "#{path}:#{number}: #{line.strip}" if line.match?(FORBIDDEN) }
    end

    def allowed?(path)
      allowed_files.key?(path) || ATTENDANCE_PAYROLL_DIRS.any? { |dir| path.start_with?(dir) }
    end
  end
end

RSpec.describe "Architecture: Attendance & Payroll employee obligation boundary" do
  boundary = ArchitectureSpecs::AttendancePayrollObligationBoundary

  it "has no direct Employee Obligations access outside Attendance & Payroll and the documented exceptions" do
    violations = boundary.source_files.reject { |path| boundary.allowed?(path) }.flat_map { |path| boundary.violations_in(path) }
    expect(violations).to be_empty, <<~MSG
      Direct access to Attendance & Payroll employee-obligation internals from outside the domain:
      #{violations.join("\n")}
      Go through Attendance & Payroll code, or document a new exception in
      next-pilot-selection.md (Milestone 2, Pilot 2) and the allow-list.
    MSG
  end

  it "keeps the allow-list tight (every listed file exists and still needs its entry)" do
    stale = boundary.allowed_files.keys.select { |path| !File.exist?(Rails.root.join(path)) || boundary.violations_in(path).empty? }
    expect(stale).to be_empty, "Remove from the allow-list: #{stale.join(', ')}"
  end

  it "keeps every allowed directory in use" do
    unused = boundary::ATTENDANCE_PAYROLL_DIRS.reject do |dir|
      boundary.source_files.any? { |path| path.start_with?(dir) && boundary.violations_in(path).any? }
    end
    expect(unused).to be_empty, "Remove from the allowed directories: #{unused.join(', ')}"
  end

  describe "self-tests" do
    it "allows an Attendance & Payroll file and a documented exception, and rejects any other domain" do
      expect(boundary.allowed?("app/services/payroll/obligation_editor.rb")).to be(true)
      expect(boundary.allowed?("app/views/admin/employee_obligations/show.html.erb")).to be(true)
      expect(boundary.allowed?("app/models/business.rb")).to be(true)
      expect(boundary.allowed?("app/services/finance/reports/expense_details.rb")).to be(false)
      expect(boundary.allowed?("app/services/payroll/approver.rb")).to be(false)
      expect(boundary.allowed?("app/controllers/admin/users_controller.rb")).to be(false)
    end

    it "matches every guarded constant, collection and table" do
      [
        "EmployeeObligation.where(user: user)", "ObligationDeduction.create!(attrs)",
        "ObligationPostponement.where(id: ids)", "business.employee_obligations.active",
        "period.obligation_deductions.destroy_all", "obligation.obligation_postponements.to_a",
        "Payroll::ObligationEditor.call(**args)", "Payroll::ObligationInstallmentPostponer.call(**args)",
        "ObligationDeductor.call(user: u, period: p)"
      ].each { |code| expect(code).to match(boundary::FORBIDDEN), code }
    end

    it "is not so broad that it guards payroll-core line items, columns, policies or routes" do
      [
        "li.obligation_deduction?", 'item_type: "obligation_deduction"', "entry.obligations_deducted",
        "authorize EmployeeObligationPolicy", "admin_employee_obligations_path(filters)",
        "new_admin_employee_obligation_path(user_id: id)", "user.can?(:manage_obligations)",
        "obligation_status_badge(obligation.status)", "joins(:employee_obligation)"
      ].each { |code| expect(code).not_to match(boundary::FORBIDDEN), code }
    end

    it "flags a guarded reference in a file outside the allow-list" do
      external = "app/services/finance/reports/hypothetical.rb"
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(Rails.root.join(external)).and_return("EmployeeObligation.sum(:remaining_amount)\n")

      expect(boundary.allowed?(external)).to be(false)
      expect(boundary.violations_in(external)).to eq([ "#{external}:1: EmployeeObligation.sum(:remaining_amount)" ])
    end

    it "ignores guarded names in comments only" do
      path = "app/services/hypothetical_comment.rb"
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(Rails.root.join(path)).and_return("# EmployeeObligation is AP-owned\n")

      expect(boundary.violations_in(path)).to be_empty
    end
  end
end
