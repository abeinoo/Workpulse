require "rails_helper"

# Boundary for the Workforce Shifts & Scheduling group (module-boundaries.md §5:
# shifts, assignments, templates, rule profiles, scheduling, branch membership)
# against Attendance & Payroll — F2 (§13 cycle F2;
# docs/architecture/workforce-shift-assignment-attendance-baseline-failures.txt).
#
# Rules:
# 1. No Shifts & Scheduling file names an Attendance & Payroll constant, except the
#    Pilot 4 penalty-rule option lists of the shift form (classified, frozen at
#    their current lines — attendance_payroll_penalty_rule_boundary_spec.rb).
# 2. No Shifts & Scheduling file names an Attendance & Payroll table — strings
#    included, so raw SQL cannot read attendance or payroll behind the contract.
# 3. Whether attendance was recorded against an assignment is asked only through
#    the Workforce contract Shifts::AttendanceUsage, at exactly its two call sites.
# 4. The contract names nothing from Attendance & Payroll; the implementation
#    never calls back into Workforce and is named only by the composition root;
#    it is the registered handler.
module ArchitectureSpecs
  module WorkforceShiftSchedulingBoundary
    module_function

    CONTRACT_FILE    = "app/services/shifts/attendance_usage.rb".freeze
    IMPLEMENTATION   = "app/services/attendance/shift_assignment_usage.rb".freeze
    COMPOSITION_ROOT = "config/initializers/shift_attendance_usage.rb".freeze

    GLOBS = %w[
      app/models/shift.rb app/models/shift_assignment.rb app/models/shift_template.rb
      app/models/shift_template_entry.rb app/models/shift_rule_profile.rb
      app/services/shifts/**/*.rb app/services/scheduling/**/*.rb app/services/branch_membership.rb
      app/services/workforce/**/*.rb
      app/controllers/shifts_controller.rb app/controllers/shift_assignments_controller.rb
      app/controllers/admin/shifts_controller.rb app/controllers/admin/shift_templates_controller.rb
      app/controllers/admin/shift_rule_profiles_controller.rb
      app/controllers/api/v1/shifts_controller.rb app/controllers/api/v1/shift_assignments_controller.rb
      app/views/shifts/**/*.erb app/views/shift_assignments/**/*.erb app/views/admin/shifts/**/*.erb
      app/views/admin/shift_templates/**/*.erb app/views/admin/shift_rule_profiles/**/*.erb
      app/policies/shift_policy.rb app/policies/shift_assignment_policy.rb app/policies/shift_template_policy.rb
      app/policies/shift_rule_profile_policy.rb
      app/helpers/shift_assignment_helper.rb app/helpers/shift_template_helper.rb
    ].freeze

    AP_MODELS = %w[
      AttendanceRecord AttendanceAdjustment AttendanceImportLog BiometricDevice BiometricPunchLog PenaltyRule
      SalaryProfile PayrollPeriod PayrollEntry PayrollLineItem PayrollAdjustment PayrollAdjustmentEdit PayrollAuditLog
      PayrollSnapshot PayrollPeriodBranchReview Advance EmployeeObligation ObligationDeduction ObligationPostponement
    ].freeze
    AP_CONSTANT = /\b(?:#{AP_MODELS.join('|')})\b|\b(?:Attendance|Payroll|Salary|Adjustments)::/
    AP_TABLE    = /\b(?:attendance_records|attendance_adjustments|attendance_import_logs|payroll_(?:periods|entries|line_items|adjustments|snapshots)|salary_profiles|advances|employee_obligations)\b/

    # Rule 1 exception: file → the exact classified lines (Pilot 4).
    CLASSIFIED = { "app/views/admin/shifts/_form.html.erb" => 4 }.freeze

    CALL = /Shifts::AttendanceUsage\.(\w+[?!]?)/
    CALL_SITES = {
      "app/models/shift_assignment.rb"                  => %w[recorded_against?],
      "app/controllers/shift_assignments_controller.rb" => %w[recorded_against_sql]
    }.freeze

    def files = GLOBS.flat_map { Dir.glob(Rails.root.join(_1)) }.map { _1.delete_prefix("#{Rails.root}/") }.uniq.sort

    def source_files(root = "{app,lib}")
      Dir.glob(Rails.root.join("#{root}/**/*.{rb,erb,rake}")).map { |f| f.delete_prefix("#{Rails.root}/") }.sort
    end

    # Code lines (comments dropped). `keep_strings` keeps string contents, for
    # SQL table names (rule 2); otherwise strings are blanked (rule 1).
    def code_lines(path, keep_strings: false)
      source = File.read(Rails.root.join(path))
      source = source.gsub(/<%#.*?%>/m) { |c| "\n" * c.count("\n") } if path.end_with?(".erb")
      source.each_line.with_index(1).reject { |line, _| line.lstrip.start_with?("#") }.map do |line, number|
        line = line.gsub(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/, '""') unless keep_strings
        [ line.sub(/\s#\s.*$/, ""), number ]
      end
    end

    def matches_in(path, pattern, keep_strings: false)
      code_lines(path, keep_strings: keep_strings).filter_map do |line, number|
        "#{path}:#{number}: #{line.strip}" if line.match?(pattern)
      end
    end

    # Rule 2 ignores i18n keys (t("payroll_entries.x") / t(".x")) — they name translations, not tables.
    def table_matches_in(path)
      matches_in(path, AP_TABLE, keep_strings: true).select { _1.gsub(/\bt\(\s*"[^"]*"/, "").match?(AP_TABLE) }
    end

    def calls_in(path) = code_lines(path).flat_map { |line, _| line.scan(CALL).flatten }.uniq.sort
  end
end

RSpec.describe "Architecture: Workforce Shifts & Scheduling reads Attendance & Payroll only through Shifts::AttendanceUsage (F2)" do
  boundary = ArchitectureSpecs::WorkforceShiftSchedulingBoundary

  it "covers every glob (no stale glob or classified file)" do
    empty = boundary::GLOBS.select { |glob| Dir.glob(Rails.root.join(glob)).empty? }
    expect(empty).to be_empty, "Remove or fix: #{empty.join(', ')}"
    expect(boundary::CLASSIFIED.keys + boundary::CALL_SITES.keys - boundary.files).to be_empty
  end

  it "names no Attendance & Payroll constant outside the classified penalty-rule option lists (rule 1)" do
    found = boundary.files.to_h { |path| [ path, boundary.matches_in(path, boundary::AP_CONSTANT).size ] }.reject { _2.zero? }
    expect(found).to eq(boundary::CLASSIFIED)
    expect(boundary.matches_in("app/views/admin/shifts/_form.html.erb", boundary::AP_CONSTANT))
      .to all(match(/PenaltyRule::(RULE_TYPES|DEDUCTION_TYPES)/))
  end

  it "names no Attendance & Payroll table, strings included (rule 2)" do
    found = boundary.files.flat_map { |path| boundary.table_matches_in(path) }
    expect(found).to be_empty, "Ask through Shifts::AttendanceUsage:\n#{found.join("\n")}"
  end

  it "asks about attendance only at the two classified call sites (rule 3)" do
    callers = boundary.files.to_h { |path| [ path, boundary.calls_in(path) ] }.reject { _2.empty? }
    callers.delete(boundary::CONTRACT_FILE)
    expect(callers).to eq(boundary::CALL_SITES)
  end

  it "has a contract that names nothing from Attendance & Payroll (rule 4)" do
    expect(boundary.matches_in(boundary::CONTRACT_FILE, boundary::AP_CONSTANT)).to be_empty
    expect(boundary.matches_in(boundary::CONTRACT_FILE, boundary::AP_TABLE, keep_strings: true)).to be_empty
  end

  it "has an implementation that never calls back into Workforce, named only by the composition root (rule 4)" do
    expect(boundary.matches_in(boundary::IMPLEMENTATION, /\bShiftAssignment\b|\bShifts::|\bScheduling::|\bBranchMembership\b/))
      .to be_empty
    outside = (boundary.source_files + boundary.source_files("config"))
              .reject { [ boundary::IMPLEMENTATION, boundary::COMPOSITION_ROOT ].include?(_1) }
              .flat_map { boundary.matches_in(_1, /\bAttendance::ShiftAssignmentUsage\b/) }
    expect(outside).to be_empty
    expect(boundary.matches_in(boundary::COMPOSITION_ROOT,
                               /Shifts::AttendanceUsage\.register\(Attendance::ShiftAssignmentUsage\)/)).to be_present
    expect(Shifts::AttendanceUsage.handler).to equal(Attendance::ShiftAssignmentUsage)
  end

  describe "self-tests" do
    def plant(path, content)
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(Rails.root.join(path)).and_return(content)
    end

    it "catches the former direct reads planted back" do
      model = "app/models/shift_assignment.rb"
      plant(model, "def x = AttendanceRecord.where(shift_assignment_id: id).exists?\n")
      expect(boundary.matches_in(model, boundary::AP_CONSTANT)).not_to be_empty

      controller = "app/controllers/shift_assignments_controller.rb"
      plant(controller, "Arel.sql(\"EXISTS(SELECT 1 FROM attendance_records ar WHERE x)\")\n")
      expect(boundary.table_matches_in(controller)).not_to be_empty
    end

    it "ignores comments, i18n keys and the contract's own name" do
      path = "app/views/shifts/show.html.erb"
      plant(path, "<%# AttendanceRecord %>\n# attendance_records\n<%= t(\"payroll_entries.title\") %>\n" \
                  "Shifts::AttendanceUsage.recorded_against?(assignment_id: 1)\n")
      expect(boundary.matches_in(path, boundary::AP_CONSTANT)).to be_empty
      expect(boundary.table_matches_in(path)).to be_empty
    end
  end
end
