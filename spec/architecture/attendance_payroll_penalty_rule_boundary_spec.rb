require "rails_helper"

# Boundary enforcement for Pilot 4 — Attendance & Payroll Penalty Rules (M6; see
# docs/architecture/next-pilot-selection.md §19).
#
# PenaltyRule (table penalty_rules), PenaltyRulePolicy, the penalty-rule
# controllers, Attendance::PenaltyCalculator and Attendance::ShiftPenaltyRules
# are owned by Attendance & Payroll. Workforce sits upstream: since M2–M4 the
# Shift form stages its rule rows only through the Workforce-defined
# Shifts::PenaltyRuleSettings contract, implemented by Attendance & Payroll and
# wired in config/initializers/shift_penalty_rule_settings.rb.
#
# Two boundaries:
# 1. Penalty-rule internals (the class, the collection/table, the calculator
#    and the contract implementation) may be named only by Attendance &
#    Payroll and the classified exceptions below; read exceptions stay
#    read-only.
# 2. Workforce code never writes penalty rules nor names the Attendance &
#    Payroll implementation; it may use the contract, read rules for display,
#    and read the two option lists PenaltyRule::RULE_TYPES / DEDUCTION_TYPES.
#
# Not guarded: route helpers (admin_shift_penalty_rules_path …), i18n keys
# (t("penalty_rules.…")), PenaltyRulePolicy, the shift form's HTTP parameter
# name penalty_rules_attributes, CSS classes, JavaScript, and config/ (routes,
# locales), as in the other boundary specs.
#
# This spec fails on any NEW direct reference outside the allow-list below.
# Adding to the allow-list is an architectural decision: give the reason.
module ArchitectureSpecs
  module AttendancePayrollPenaltyRuleBoundary
    module_function

    FORBIDDEN = /
      \bPenaltyRule\b             # the model (not PenaltyRulePolicy, not Shifts::PenaltyRuleSettings)
      | \bpenalty_rules\b         # the collection and the table
      | \bPenaltyCalculator\b     # Attendance::PenaltyCalculator
      | \bShiftPenaltyRules\b     # the contract implementation
    /x

    # Attendance & Payroll-owned code (module-boundaries.md §6).
    ATTENDANCE_PAYROLL_FILES = {
      "app/models/attendance_payroll/penalty_rule.rb"    => "the model itself (folder collapsed: top-level constant)",
      "app/controllers/admin/penalty_rules_controller.rb" => "AP penalty-rule administration (PenaltyRulePolicy)",
      "app/controllers/api/v1/penalty_rules_controller.rb" => "AP penalty-rule API (ShiftPolicy)",
      "app/services/attendance/penalty_calculator.rb"    => "AP penalty calculation",
      "app/services/attendance/time_calculator.rb"       => "AP lateness thresholds from rules",
      "app/services/attendance/record_recomputer.rb"     => "AP attendance recompute (preloads rules)",
      "app/services/attendance/status_backfill.rb"       => "AP status backfill (preloads rules)",
      "app/services/attendance/shift_penalty_rules.rb"   => "AP implementation of Shifts::PenaltyRuleSettings",
      "app/services/payroll/entry_calculator.rb"         => "AP payroll: penalty line items",
      "app/services/payroll/permission_applier.rb"       => "AP payroll: permission penalty adjustment",
      "app/services/payroll/punch_correction_applier.rb" => "AP payroll: punch-correction penalty adjustment"
    }.freeze

    ATTENDANCE_PAYROLL_DIRS = [
      "app/views/admin/penalty_rules/" # AP penalty-rule administration screens
    ].freeze

    # Workforce Shift: the inverse association that owns the rules' lifecycle.
    LIFECYCLE_FILES = {
      "app/models/shift.rb" => "WF Shift has_many :penalty_rules, dependent: :destroy, autosave: true — " \
                               "rules live and die with their shift; autosave persists the rows staged " \
                               "by the contract in the shift's own save (M4)"
    }.freeze

    # Read-only display of rules (UI / API composition).
    READ_FILES = {
      "app/views/admin/shifts/_form.html.erb"        => "WF shift form: renders the staged rule rows and reads PenaltyRule::RULE_TYPES / DEDUCTION_TYPES",
      "app/controllers/admin/shifts_controller.rb"   => "WF admin shift page: loads the rules for display (#show)",
      "app/views/admin/shifts/show.html.erb"         => "WF admin shift page: lists the rules",
      "app/controllers/shifts_controller.rb"         => "WF employee shift page: loads the rules for display",
      "app/views/shifts/show.html.erb"               => "WF employee shift page: lists the rules",
      "app/controllers/api/v1/shifts_controller.rb"  => "WF API shift show: includes the rules (legacy raw attributes)",
      "app/controllers/admin/branches_controller.rb" => "OA branch staff view: preloads shift: :penalty_rules (see BRANCH_STAFF_RULE_COUNT)",
      "app/views/admin/branches/_shifts.html.erb"    => "OA branch staff view: shows each shift's rule count (see BRANCH_STAFF_RULE_COUNT)"
    }.freeze

    # Documented cross-domain writes of the WF ↔ AP employee-request cycle
    # (module-boundaries.md §14.2 #3 / #4); outside this pilot. They compute
    # penalties and preload rules but never write penalty_rules.
    REQUEST_EXCEPTION_FILES = {
      "app/services/requests/canceller.rb"               => "§14.2 #4: restores penalty line items via Attendance::PenaltyCalculator",
      "app/services/requests/punch_correction_applier.rb" => "§14.2 #3: preloads rules for the corrected record"
    }.freeze

    UI_SHELL_FILES = {
      "app/helpers/workspace_helper.rb" => "UI shell: workspace navigation lists the admin/penalty_rules controller path"
    }.freeze

    # The OA branch staff view's penalty-rule count (found in M0 §19.4). Decision
    # (M6): an explicit, read-only exception. It rides on the documented OA → WF
    # branch-staff-view exception (module-boundaries.md §12.2) and is resolved
    # with it; it may only preload the rules and count them.
    BRANCH_STAFF_RULE_COUNT = {
      "app/controllers/admin/branches_controller.rb" => [ /\bshift: :penalty_rules\b/ ],
      "app/views/admin/branches/_shifts.html.erb"    => [ /\.shift\.penalty_rules\.size\b/ ]
    }.freeze

    # The only lines app/models/shift.rb may contain about penalty rules.
    SHIFT_LIFECYCLE = /\Ahas_many :penalty_rules,\s+dependent: :destroy, autosave: true\z/

    COMPOSITION_ROOT = "config/initializers/shift_penalty_rule_settings.rb".freeze

    WRITE_CALL = /\.(?:create|update|update_all|update_columns?|save|destroy|destroy_all|delete|delete_all|
                    insert_all|upsert_all|build|new|find_or_create_by|clear|mark_for_destruction)!?(?=[(\s]|$)
                  | <<\s | penalty_rules_attributes\s*=(?!=) | accepts_nested_attributes_for/x

    def exception_files
      LIFECYCLE_FILES.merge(READ_FILES).merge(REQUEST_EXCEPTION_FILES).merge(UI_SHELL_FILES)
    end

    def allowed_files = ATTENDANCE_PAYROLL_FILES.merge(exception_files)

    def source_files(root = "{app,lib}")
      Dir.glob(Rails.root.join("#{root}/**/*.{rb,erb,rake}")).map { |f| f.delete_prefix("#{Rails.root}/") }.sort
    end

    # Full-line Ruby comments, ERB comments (including multi-line) and t(...)
    # i18n keys are ignored.
    def code_lines(path)
      source = File.read(Rails.root.join(path))
      source = source.gsub(/<%#.*?%>/m) { |c| "\n" * c.count("\n") } if path.end_with?(".erb")
      source.each_line.with_index(1)
            .reject { |line, _| line.lstrip.start_with?("#") }
            .map { |line, number| [ line.gsub(/\b(?:I18n\.)?t\(\s*(["'])[^"']*\1/, 't("KEY"'), number ] }
    end

    def matches_in(path, pattern)
      code_lines(path).filter_map { |line, number| "#{path}:#{number}: #{line.strip}" if line.match?(pattern) }
    end

    def violations_in(path) = matches_in(path, FORBIDDEN)

    def allowed?(path)
      allowed_files.key?(path) || ATTENDANCE_PAYROLL_DIRS.any? { |dir| path.start_with?(dir) }
    end
  end

  module WorkforcePenaltyRuleContract
    module_function

    # Workforce code (module-boundaries.md §5 / §10).
    WORKFORCE_GLOBS = %w[
      app/models/workforce/**/*.rb
      app/models/{shift,shift_assignment,shift_template,shift_template_entry,shift_rule_profile,employee_request,employee_insurance_profile}.rb
      app/services/{shifts,scheduling,requests,employee,employee_data_requests,performance}/**/*.rb
      app/controllers/{shifts,shift_assignments,employee_requests}_controller.rb
      app/controllers/admin/{shifts,shift_templates,shift_rule_profiles,departments,job_titles,employee_insurance_profiles}_controller.rb
      app/controllers/api/v1/{shifts,shift_assignments,employee_requests}_controller.rb
      app/views/{shifts,shift_assignments,employee_requests}/**/*.erb
      app/views/admin/{shifts,shift_templates,shift_rule_profiles}/**/*.erb
      app/policies/{shift,shift_assignment,shift_template,shift_rule_profile,employee_request}_policy.rb
    ].freeze

    # Writing penalty rules, the nested-attributes mechanism, or naming the AP
    # implementation. PenaltyRule may be named only for its two option lists.
    FORBIDDEN_IN_WORKFORCE = /
      \bShiftPenaltyRules\b
      | \bPenaltyRule\b(?!::(?:RULE_TYPES|DEDUCTION_TYPES)\b)
      | accepts_nested_attributes_for\s+:penalty_rules
      | penalty_rules_attributes\s*=(?!=)
      | \.penalty_rules\.(?:build|new|create|create!|destroy|destroy_all|delete|delete_all|update_all|insert_all|upsert_all|clear)\b
      | \.penalty_rules\s*<<
    /x

    CONTRACT_FILE = "app/services/shifts/penalty_rule_settings.rb".freeze

    def workforce_files
      WORKFORCE_GLOBS.flat_map { |glob| Dir.glob(Rails.root.join(glob)) }
                     .map { |f| f.delete_prefix("#{Rails.root}/") }.uniq.sort
    end
  end
end

RSpec.describe "Architecture: Attendance & Payroll penalty rule boundary" do
  boundary = ArchitectureSpecs::AttendancePayrollPenaltyRuleBoundary

  it "has no direct penalty-rule access outside Attendance & Payroll and the classified exceptions" do
    violations = boundary.source_files.reject { |path| boundary.allowed?(path) }.flat_map { |path| boundary.violations_in(path) }
    expect(violations).to be_empty, <<~MSG
      Direct access to Attendance & Payroll penalty-rule internals from outside the domain:
      #{violations.join("\n")}
      Go through Shifts::PenaltyRuleSettings (Workforce) or Attendance & Payroll code, or classify a new
      exception in next-pilot-selection.md (§19) and the allow-list.
    MSG
  end

  it "keeps every read and request exception read-only on penalty rules" do
    files  = boundary::READ_FILES.keys + boundary::REQUEST_EXCEPTION_FILES.keys + boundary::UI_SHELL_FILES.keys
    writes = files.flat_map { |path| boundary.violations_in(path) }.grep(boundary::WRITE_CALL)
    expect(writes).to be_empty, "These exceptions must not write penalty rules:\n#{writes.join("\n")}"
  end

  it "limits the OA branch staff view to preloading and counting rules (M6 decision)" do
    boundary::BRANCH_STAFF_RULE_COUNT.each do |path, shapes|
      lines = boundary.violations_in(path)
      expect(lines).not_to be_empty, "#{path} no longer reads penalty rules — remove its exception"
      unexpected = lines.reject { |line| shapes.any? { |shape| line.match?(shape) } }
      expect(unexpected).to be_empty, "Branch staff view may only preload/count rules:\n#{unexpected.join("\n")}"
    end
  end

  it "keeps the Shift lifecycle association exactly as classified" do
    lines = boundary.violations_in("app/models/shift.rb").map { |line| line.split(": ", 2).last }
    expect(lines).to all(match(boundary::SHIFT_LIFECYCLE))
    expect(lines.size).to eq(1)

    reflection = Shift.reflect_on_association(:penalty_rules)
    expect(reflection).to have_attributes(macro: :has_many, class_name: "PenaltyRule")
    expect(reflection.options).to include(dependent: :destroy, autosave: true)
    expect(Shift.nested_attributes_options).not_to have_key(:penalty_rules)
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
    it "allows Attendance & Payroll files and the classified exceptions, and rejects any other file" do
      expect(boundary.allowed?("app/services/attendance/shift_penalty_rules.rb")).to be(true)
      expect(boundary.allowed?("app/views/admin/penalty_rules/edit.html.erb")).to be(true)
      expect(boundary.allowed?("app/models/shift.rb")).to be(true)
      expect(boundary.allowed?("app/views/admin/branches/_shifts.html.erb")).to be(true)
      expect(boundary.allowed?("app/services/shifts/assigner.rb")).to be(false)
      expect(boundary.allowed?("app/services/finance/reports/expense_details.rb")).to be(false)
      expect(boundary.allowed?("app/controllers/admin/users_controller.rb")).to be(false)
    end

    it "matches every guarded name, and not policies, the contract, route helpers or CSS classes" do
      [
        "PenaltyRule.where(shift: s)", "shift.penalty_rules.size", "includes(shift: :penalty_rules)",
        "Attendance::PenaltyCalculator.calculate(**args)", "Attendance::ShiftPenaltyRules.assign(**args)"
      ].each { |code| expect(code).to match(boundary::FORBIDDEN), code }
      [
        "authorize @rule, policy_class: PenaltyRulePolicy", "Shifts::PenaltyRuleSettings.assign(shift: s, rows: r)",
        "admin_shift_penalty_rules_path(shift)", 'class="penalty-rules-section"', "late_penalty"
      ].each { |code| expect(code).not_to match(boundary::FORBIDDEN), code }
    end

    it "flags a guarded reference planted outside the allow-list" do
      external = "app/services/shifts/hypothetical.rb"
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(Rails.root.join(external)).and_return("PenaltyRule.where(shift: shift).destroy_all\n")

      expect(boundary.allowed?(external)).to be(false)
      expect(boundary.violations_in(external)).to eq([ "#{external}:1: PenaltyRule.where(shift: shift).destroy_all" ])
    end

    it "flags a write planted in a read exception, and a widened branch-staff read" do
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(Rails.root.join("app/views/shifts/show.html.erb"))
        .and_return("<% @shift.penalty_rules.destroy_all %>\n")
      allow(File).to receive(:read).with(Rails.root.join("app/views/admin/branches/_shifts.html.erb"))
        .and_return("<% assignment.shift.penalty_rules.each { |r| r.deduction_value } %>\n")

      expect(boundary.violations_in("app/views/shifts/show.html.erb").grep(boundary::WRITE_CALL)).not_to be_empty
      lines = boundary.violations_in("app/views/admin/branches/_shifts.html.erb")
      expect(lines.reject { |l| boundary::BRANCH_STAFF_RULE_COUNT["app/views/admin/branches/_shifts.html.erb"].any? { |s| l.match?(s) } })
        .not_to be_empty
    end

    it "ignores guarded names in comments and i18n keys" do
      path = "app/services/hypothetical_comment.rb"
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(Rails.root.join(path))
        .and_return("# PenaltyRule is AP-owned\nlabel = t(\"penalty_rules.rule_types.late_arrival\")\n")

      expect(boundary.violations_in(path)).to be_empty
    end
  end
end

RSpec.describe "Architecture: Workforce reaches penalty rules only through Shifts::PenaltyRuleSettings" do
  contract = ArchitectureSpecs::WorkforcePenaltyRuleContract
  boundary = ArchitectureSpecs::AttendancePayrollPenaltyRuleBoundary

  it "covers every Workforce glob (no stale glob)" do
    empty = contract::WORKFORCE_GLOBS.select { |glob| Dir.glob(Rails.root.join(glob)).empty? }
    expect(empty).to be_empty, "Remove or fix: #{empty.join(', ')}"
  end

  it "Workforce code writes no penalty rule and names no Attendance & Payroll implementation" do
    violations = contract.workforce_files.flat_map { |file| boundary.matches_in(file, contract::FORBIDDEN_IN_WORKFORCE) }
    expect(violations).to be_empty, <<~MSG
      Workforce must stage penalty rules only through Shifts::PenaltyRuleSettings:
      #{violations.join("\n")}
    MSG
  end

  it "the Shift form controller stages rule rows only through the contract" do
    lines = boundary.code_lines("app/controllers/admin/shifts_controller.rb").map(&:first).join
    expect(lines).to include("Shifts::PenaltyRuleSettings.assign(shift: @shift, rows: rows)")
  end

  it "the Workforce contract names nothing from Attendance & Payroll" do
    expect(boundary.matches_in(contract::CONTRACT_FILE, /\bAttendance::|\bPayroll::|\bPenaltyRule\b|\bpenalty_rules\b/)).to be_empty
  end

  it "only the composition root and Attendance & Payroll name the implementation; it is the registered handler" do
    reference = /\bShiftPenaltyRules\b/
    outside = (boundary.source_files + boundary.source_files("config"))
              .reject { |file| file == "app/services/attendance/shift_penalty_rules.rb" || file == boundary::COMPOSITION_ROOT }
              .flat_map { |file| boundary.matches_in(file, reference) }

    expect(outside).to be_empty, "Unexpected reference to the contract implementation:\n#{outside.join("\n")}"
    expect(boundary.matches_in(boundary::COMPOSITION_ROOT,
                               /Shifts::PenaltyRuleSettings\.register\(Attendance::ShiftPenaltyRules\)/)).to be_present
    expect(Shifts::PenaltyRuleSettings.handler).to equal(Attendance::ShiftPenaltyRules)
  end

  describe "self-tests" do
    it "flags write mechanics and implementation references planted in Workforce code" do
      [
        "Attendance::ShiftPenaltyRules.assign(shift: s, rows: r)", "PenaltyRule.create!(attrs)",
        "accepts_nested_attributes_for :penalty_rules", "shift.penalty_rules_attributes = rows",
        "shift.penalty_rules.build(attrs)", "@shift.penalty_rules.destroy_all", "shift.penalty_rules << rule"
      ].each { |code| expect(code).to match(contract::FORBIDDEN_IN_WORKFORCE), code }
    end

    it "allows the contract, display reads and the two option lists" do
      [
        "Shifts::PenaltyRuleSettings.assign(shift: @shift, rows: rows)", "PenaltyRule::RULE_TYPES.map { |rt| rt }",
        "PenaltyRule::DEDUCTION_TYPES.each do |dt|", "@shift.penalty_rules.order(:threshold_minutes)",
        "params.require(:shift).permit(penalty_rules_attributes: FIELDS)", "shift.penalty_rules.any?"
      ].each { |code| expect(code).not_to match(contract::FORBIDDEN_IN_WORKFORCE), code }
    end
  end
end
