require "rails_helper"

# Boundary for Batch V — Workforce → Attendance & Payroll request-validation
# reads (D-A5; module-boundaries.md §12.2 WF → AP;
# docs/architecture/workforce-request-validation-reads-baseline-failures.txt).
#
# Workforce owns the employee-request form, show page, validation and policy;
# the advance limit, salary visibility and its audit, attendance days, recent
# check-ins and duration thresholds they read are Attendance & Payroll's. Since
# Batch V M4 they are read only through the Workforce contract
# Requests::RequestFormReads, implemented by Attendance & Payroll
# (Payroll::RequestFormReads) and wired in config/initializers/request_form_reads.rb.
#
# Rules:
# 1. Workforce request code names no Attendance & Payroll constant (models other
#    than Advance — see workforce_request_advance_boundary_spec.rb — policies,
#    Salary:: / Attendance:: / Payroll:: services); one classified exception in
#    the shared helper.
# 2. The seven read sites call the contract, with exactly the shapes below.
# 3. The contract names nothing from Attendance & Payroll; the implementation
#    never calls back into the Workforce request lifecycle; the implementation is
#    the registered handler and only the composition root names it.
module ArchitectureSpecs
  module WorkforceRequestValidationReadsBoundary
    module_function

    CONTRACT_FILE    = "app/services/requests/request_form_reads.rb".freeze
    IMPLEMENTATION   = "app/services/payroll/request_form_reads.rb".freeze
    COMPOSITION_ROOT = "config/initializers/request_form_reads.rb".freeze

    WORKFORCE_GLOBS = %w[
      app/services/requests/**/*.rb
      app/models/employee_request.rb
      app/controllers/employee_requests_controller.rb
      app/controllers/api/v1/employee_requests_controller.rb
      app/views/employee_requests/**/*.erb
      app/policies/employee_request_policy.rb
      app/helpers/application_helper.rb
    ].freeze

    AP_MODELS = %w[
      AttendanceRecord AttendanceAdjustment AttendanceImportLog BiometricDevice BiometricPunchLog PenaltyRule
      SalaryProfile PayrollPeriod PayrollEntry PayrollLineItem PayrollAdjustment PayrollAdjustmentEdit PayrollAuditLog
      PayrollSnapshot PayrollPeriodBranchReview EmployeeObligation ObligationDeduction ObligationPostponement
    ].freeze

    # An Attendance & Payroll constant: a model (or its policy) or a namespaced service.
    AP_REF = /\b(?:#{AP_MODELS.join('|')})(?:Policy)?\b|\b(?:Salary|Attendance|Payroll|Geo)::\w+/

    # Classified exceptions (rule 1): file → exact code shapes allowed there.
    EXCEPTIONS = {
      # The shared helper's payroll-adjustment badge (payroll screens), not request code.
      "app/helpers/application_helper.rb" => [ /\Aif PayrollAdjustment::POSITIVE_TYPES\.include\?\(adj\.adjustment_type\)\z/ ]
    }.freeze

    # The seven read sites (rule 2): file → the contract calls it makes.
    CONTRACT_CALLS = {
      "app/models/employee_request.rb" => [
        "Requests::RequestFormReads.advance_limit(user: user)"                                        # site 1
      ],
      "app/controllers/employee_requests_controller.rb" => [
        "Requests::RequestFormReads.attendance_day(user: @request.user, date: @request.requested_for_date)", # site 3
        "Requests::RequestFormReads.advance_limit_for(user: target_user, viewer: current_user)",       # site 2
        "Requests::RequestFormReads.recent_check_ins(user: target_user)"                              # site 4
      ],
      "app/policies/employee_request_policy.rb" => [
        "Requests::RequestFormReads.salary_visible?(viewer: user, employee: effective_user)"          # site 5
      ],
      "app/views/employee_requests/show.html.erb" => [
        "Requests::RequestFormReads.duration_threshold_hours(severity: severity, business: current_user.business)" # site 6
      ],
      "app/views/employee_requests/_resulting_duration.html.erb" => [
        "Requests::RequestFormReads.duration_threshold_hours(severity: severity, business: assessment.request.user.business)" # site 7
      ]
    }.freeze

    CONTRACT_CALL = /Requests::RequestFormReads\.\w+[?!]?\([^)]*\)/

    # A call back into the Workforce request lifecycle.
    WORKFORCE_CALLBACK = /\bRequests::(?!RequestFormReads\b)\w+|\bEmployeeRequest\b|\.(?:approve|reject|cancel|pay)[!(\s]/

    def source_files(root = "{app,lib}")
      Dir.glob(Rails.root.join("#{root}/**/*.{rb,erb,rake}")).map { |f| f.delete_prefix("#{Rails.root}/") }.sort
    end

    def workforce_files
      WORKFORCE_GLOBS.flat_map { |glob| Dir.glob(Rails.root.join(glob)) }.map { |f| f.delete_prefix("#{Rails.root}/") }.uniq.sort
    end

    # Code only: full-line comments and ERB comments dropped, string contents
    # blanked (unless keep_strings), trailing comments removed.
    def code_lines(path, keep_strings: false)
      source = File.read(Rails.root.join(path))
      source = source.gsub(/<%#.*?%>/m) { |c| "\n" * c.count("\n") } if path.end_with?(".erb")
      source.each_line.with_index(1)
            .reject { |line, _| line.lstrip.start_with?("#") }
            .map do |line, number|
              line = line.gsub(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/, '""') unless keep_strings
              [ line.sub(/\s#\s.*$/, ""), number ]
            end
    end

    def matches_in(path, pattern)
      code_lines(path).filter_map { |line, number| "#{path}:#{number}: #{line.strip}" if line.match?(pattern) }
    end

    def contract_calls_in(path) = code_lines(path, keep_strings: true).flat_map { |line, _| line.scan(CONTRACT_CALL) }

    def code_of(line) = line.split(": ", 2).last.strip
  end
end

RSpec.describe "Architecture: Workforce reads Attendance & Payroll request data only through Requests::RequestFormReads" do
  boundary = ArchitectureSpecs::WorkforceRequestValidationReadsBoundary

  it "covers every Workforce glob (no stale glob)" do
    empty = boundary::WORKFORCE_GLOBS.select { |glob| Dir.glob(Rails.root.join(glob)).empty? }
    expect(empty).to be_empty, "Remove or fix: #{empty.join(', ')}"
  end

  it "Workforce request code names no Attendance & Payroll constant outside the classified exception (rule 1)" do
    unexpected = boundary.workforce_files.flat_map do |path|
      shapes = boundary::EXCEPTIONS.fetch(path, [])
      boundary.matches_in(path, boundary::AP_REF).reject { |line| shapes.any? { |shape| boundary.code_of(line).match?(shape) } }
    end
    expect(unexpected).to be_empty, <<~MSG
      Read Attendance & Payroll data through Requests::RequestFormReads (or classify the exception):
      #{unexpected.join("\n")}
    MSG
  end

  it "keeps the classified exception exactly as classified (no stale or widened entry)" do
    counts = boundary::EXCEPTIONS.keys.to_h { |path| [ path, boundary.matches_in(path, boundary::AP_REF).size ] }
    expect(counts).to eq("app/helpers/application_helper.rb" => 1)
  end

  it "the seven read sites call the contract with exactly the classified shapes, and nothing else does (rule 2)" do
    calls = boundary.workforce_files.to_h { |path| [ path, boundary.contract_calls_in(path) ] }.reject { |_, list| list.empty? }
    calls.delete(boundary::CONTRACT_FILE)
    expect(calls).to eq(boundary::CONTRACT_CALLS)
  end

  it "the contract names nothing from Attendance & Payroll (rule 3)" do
    expect(boundary.matches_in(boundary::CONTRACT_FILE, boundary::AP_REF)).to be_empty
    expect(boundary.matches_in(boundary::CONTRACT_FILE, /\bAdvance\b/)).to be_empty
  end

  it "the implementation never calls back into the Workforce request lifecycle (rule 3)" do
    expect(boundary.matches_in(boundary::IMPLEMENTATION, boundary::WORKFORCE_CALLBACK)).to be_empty
  end

  it "only the composition root and Attendance & Payroll name the implementation; it is the registered handler" do
    outside = (boundary.source_files + boundary.source_files("config"))
              .reject { |file| [ boundary::IMPLEMENTATION, boundary::COMPOSITION_ROOT ].include?(file) }
              .flat_map { |file| boundary.matches_in(file, /\bPayroll::RequestFormReads\b/) }
    expect(outside).to be_empty, "Unexpected reference to the implementation:\n#{outside.join("\n")}"
    expect(boundary.matches_in(boundary::COMPOSITION_ROOT,
                               /Requests::RequestFormReads\.register\(Payroll::RequestFormReads\)/)).to be_present
    expect(Requests::RequestFormReads.handler).to equal(Payroll::RequestFormReads)
  end

  describe "self-tests" do
    def plant(path, content)
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(Rails.root.join(path)).and_return(content)
    end

    it "catches each of the seven former direct reads planted back into Workforce code" do
      [
        "Salary::AdvanceEligibilityCalculator.for(user: user)",
        "policy(SalaryProfile.new(user_id: target_user.id)).view_salary?",
        "Salary::ViewAudit.record(actor: a, employee: e, profiles: [], source: s)",
        "AttendanceRecord.find_by(user: u, work_date: d)",
        "AttendanceRecord.where(user: u).pluck(:work_date, :check_in_at)",
        "SalaryProfilePolicy.viewable_employees(user).exists?(id: 1)",
        "Attendance::DurationCheck.threshold_hours(severity, business: b)"
      ].each { |code| expect(code).to match(boundary::AP_REF), code }
    end

    it "catches a planted read in the controller and a changed contract call shape" do
      path = "app/controllers/employee_requests_controller.rb"
      plant(path, "AttendanceRecord.find_by(user: u)\nRequests::RequestFormReads.recent_check_ins(user: current_user)\n")

      expect(boundary.matches_in(path, boundary::AP_REF)).not_to be_empty
      expect(boundary.contract_calls_in(path)).not_to eq(boundary::CONTRACT_CALLS[path])
    end

    it "does not match the contract, request columns, i18n keys or ERB comments" do
      plant("app/views/employee_requests/show.html.erb",
            "<%# Attendance::DurationCheck in a comment %>\n<%= t(\"attendance.abnormal_duration\") %>\n" \
            "<%= Requests::RequestFormReads.duration_threshold_hours(severity: s, business: b) %>\n<%= req.duration_minutes %>\n")

      expect(boundary.matches_in("app/views/employee_requests/show.html.erb", boundary::AP_REF)).to be_empty
    end

    it "catches a Workforce callback planted in the implementation" do
      plant(boundary::IMPLEMENTATION, "Requests::Approver.approve(request: r)\nEmployeeRequest.find(1)\n")

      expect(boundary.matches_in(boundary::IMPLEMENTATION, boundary::WORKFORCE_CALLBACK).size).to eq(2)
    end
  end
end
