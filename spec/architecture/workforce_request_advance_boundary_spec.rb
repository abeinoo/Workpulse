require "rails_helper"

# Boundary for Batch A — the salary-advance payment (module-boundaries.md §14.2
# #2; next-pilot-selection.md §30).
#
# Workforce owns the EmployeeRequest lifecycle; the Advance ledger it pays out
# is Attendance & Payroll's. Since Batch A, Requests::Approver#pay records the
# Advance only through the Workforce contract Requests::AdvanceEffects,
# implemented by Attendance & Payroll (Payroll::AdvanceEffects) and wired in
# config/initializers/request_advance_effects.rb.
#
# Rules:
# 1. Workforce code names no Advance constant, never creates / builds / writes an
#    Advance and never names the implementation; it may only READ the request's
#    advance at the classified sites below ("is it already paid out?", preloads
#    and the sort scope) — documented exceptions, no second read contract.
# 2. Only Attendance & Payroll code creates an Advance.
# 3. The contract names nothing from Attendance & Payroll; the implementation
#    never calls back into the Workforce request lifecycle; the implementation is
#    the registered handler and only the composition root names it.
module ArchitectureSpecs
  module WorkforceRequestAdvanceBoundary
    module_function

    CONTRACT_FILE    = "app/services/requests/advance_effects.rb".freeze
    IMPLEMENTATION   = "app/services/payroll/advance_effects.rb".freeze
    COMPOSITION_ROOT = "config/initializers/request_advance_effects.rb".freeze
    APPROVER         = "app/services/requests/approver.rb".freeze

    # Workforce request code (module-boundaries.md §5) plus the shared helper that
    # renders its "awaiting payment" state.
    WORKFORCE_GLOBS = %w[
      app/services/requests/**/*.rb
      app/models/employee_request.rb
      app/controllers/employee_requests_controller.rb
      app/controllers/api/v1/employee_requests_controller.rb
      app/views/employee_requests/**/*.erb
      app/policies/employee_request_policy.rb
      app/helpers/application_helper.rb
    ].freeze

    # Any reference to the Advance or the request's advance association (a local
    # variable that happens to be called `advance` is not one).
    ADVANCE_REF = /
      \bAdvance\b
      | \.advance\b | :advance\b
      | \b(?:create|build|reload)_advance\b
      | \bPayroll::AdvanceEffects\b
    /x

    # The classified read sites (rule 1): file → the exact shapes allowed there.
    READ_SITES = {
      "app/models/employee_request.rb" => [
        /\Ahas_one\s+:advance, dependent: :destroy\z/, # lifecycle association (the Advance belongs to its request)
        /\Aleft_joins\(:advance\)\z/                   # "awaiting payment" sort scope
      ],
      "app/controllers/employee_requests_controller.rb" => [
        /\Abase\.left_joins\(:advance\)\z/,            # index sort
        /includes\(:user, :advance\)/,                 # index / bulk_pay preload (two lines)
        /\.reject \{ \|r\| r\.advance\.present\? \}\z/ # mark_all_paid filter
      ],
      "app/views/employee_requests/index.html.erb" => [ /\b(?:r|req)\.advance\.nil\?/ ], # awaiting-payment display (two lines)
      "app/helpers/application_helper.rb"            => [ /\Arequest\.advance\.nil\?\z/ ],
      "app/services/requests/bulk_payment_service.rb" => [ /request\.advance\.present\?/ ], # skip reason
      APPROVER                                        => [ /@request\.advance\.nil\?/ ]    # payable?
    }.freeze
    READ_SITE_COUNTS = {
      "app/models/employee_request.rb" => 2, "app/controllers/employee_requests_controller.rb" => 4,
      "app/views/employee_requests/index.html.erb" => 2, "app/helpers/application_helper.rb" => 1,
      "app/services/requests/bulk_payment_service.rb" => 1, APPROVER => 1
    }.freeze

    ADVANCE_CREATE = /\bAdvance\.(?:create|new|insert|insert_all|upsert|upsert_all|find_or_create_by|create_or_find_by)!?\b/

    # A call back into the Workforce request lifecycle.
    WORKFORCE_CALLBACK = /\bRequests::\w+|\bEmployeeRequest\b|\.(?:approve|reject|cancel|pay)[!(\s]|\bupdate!?\(\s*status:|\bstatus\s*=(?!=)/

    def source_files(root = "{app,lib}")
      Dir.glob(Rails.root.join("#{root}/**/*.{rb,erb,rake}")).map { |f| f.delete_prefix("#{Rails.root}/") }.sort
    end

    def workforce_files
      WORKFORCE_GLOBS.flat_map { |glob| Dir.glob(Rails.root.join(glob)) }.map { |f| f.delete_prefix("#{Rails.root}/") }.uniq.sort
    end

    # Code only: full-line comments and ERB comments dropped, string contents
    # blanked, trailing comments removed.
    def code_lines(path)
      source = File.read(Rails.root.join(path))
      source = source.gsub(/<%#.*?%>/m) { |c| "\n" * c.count("\n") } if path.end_with?(".erb")
      source.each_line.with_index(1)
            .reject { |line, _| line.lstrip.start_with?("#") }
            .map { |line, number| [ line.gsub(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/, '""').sub(/\s#\s.*$/, ""), number ] }
    end

    def matches_in(path, pattern)
      code_lines(path).filter_map { |line, number| "#{path}:#{number}: #{line.strip}" if line.match?(pattern) }
    end

    def code_of(line) = line.split(": ", 2).last.strip
  end
end

RSpec.describe "Architecture: Workforce reaches the Advance only through Requests::AdvanceEffects" do
  boundary = ArchitectureSpecs::WorkforceRequestAdvanceBoundary

  it "covers every Workforce glob (no stale glob)" do
    empty = boundary::WORKFORCE_GLOBS.select { |glob| Dir.glob(Rails.root.join(glob)).empty? }
    expect(empty).to be_empty, "Remove or fix: #{empty.join(', ')}"
  end

  it "Workforce references the advance only at the classified read sites (rule 1)" do
    unexpected = boundary.workforce_files.flat_map do |path|
      shapes = boundary::READ_SITES.fetch(path, [])
      boundary.matches_in(path, boundary::ADVANCE_REF).reject { |line| shapes.any? { |shape| boundary.code_of(line).match?(shape) } }
    end
    expect(unexpected).to be_empty, <<~MSG
      Workforce must record the Advance only through Requests::AdvanceEffects and read it only at the classified sites:
      #{unexpected.join("\n")}
    MSG
  end

  it "keeps each read site exactly as classified (no stale or widened entry)" do
    counts = boundary::READ_SITES.keys.to_h { |path| [ path, boundary.matches_in(path, boundary::ADVANCE_REF).size ] }
    expect(counts).to eq(boundary::READ_SITE_COUNTS)
  end

  it "only Attendance & Payroll creates an Advance (rule 2)" do
    creators = boundary.source_files.flat_map { |path| boundary.matches_in(path, boundary::ADVANCE_CREATE) }
    expect(creators.map { |line| line.split(":", 2).first }.uniq).to eq([ boundary::IMPLEMENTATION ])
  end

  it "the approver records the advance through the contract, once, in pay" do
    code = boundary.code_lines(boundary::APPROVER).map(&:first)
    calls = code.grep(/Requests::AdvanceEffects\.advance_paid/)
    expect(calls.map(&:strip)).to eq([ "Requests::AdvanceEffects.advance_paid(request: @request, paid_at: paid_at)" ])
  end

  it "the contract names nothing from Attendance & Payroll (rule 3)" do
    expect(boundary.matches_in(boundary::CONTRACT_FILE, /\bPayroll\b|\bAdvance\b|\b(?:Attendance|Salary)::/)).to be_empty
  end

  it "the implementation never calls back into the Workforce request lifecycle (rule 3)" do
    expect(boundary.matches_in(boundary::IMPLEMENTATION, boundary::WORKFORCE_CALLBACK)).to be_empty
  end

  it "only the composition root and Attendance & Payroll name the implementation; it is the registered handler" do
    outside = (boundary.source_files + boundary.source_files("config"))
              .reject { |file| [ boundary::IMPLEMENTATION, boundary::COMPOSITION_ROOT ].include?(file) }
              .flat_map { |file| boundary.matches_in(file, /\bPayroll::AdvanceEffects\b/) }
    expect(outside).to be_empty, "Unexpected reference to the implementation:\n#{outside.join("\n")}"
    expect(boundary.matches_in(boundary::COMPOSITION_ROOT,
                               /Requests::AdvanceEffects\.register\(Payroll::AdvanceEffects\)/)).to be_present
    expect(Requests::AdvanceEffects.handler).to equal(Payroll::AdvanceEffects)
  end

  describe "self-tests" do
    def plant(path, content)
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(Rails.root.join(path)).and_return(content)
    end

    it "catches an Advance write planted back into the approver" do
      plant(boundary::APPROVER, "Advance.create!(user: u, employee_request: r)\n@request.advance.nil?\n")

      lines = boundary.matches_in(boundary::APPROVER, boundary::ADVANCE_REF)
      shapes = boundary::READ_SITES[boundary::APPROVER]
      expect(lines.reject { |l| shapes.any? { |s| boundary.code_of(l).match?(s) } }).not_to be_empty
      expect(boundary.matches_in(boundary::APPROVER, boundary::ADVANCE_CREATE)).not_to be_empty
    end

    it "catches association writes and the implementation named in Workforce code" do
      [
        "request.create_advance(total_amount: 1)", "request.build_advance(attrs)", "request.advance.update!(status: s)",
        "request.advance.destroy", "Payroll::AdvanceEffects.advance_paid(request: r, paid_at: t)"
      ].each { |code| expect(code).to match(boundary::ADVANCE_REF), code }
      shapes = boundary::READ_SITES.values.flatten
      expect([ "request.advance.update!(status: s)", "request.advance.destroy" ]
        .reject { |code| shapes.any? { |s| code.match?(s) } }.size).to eq(2)
    end

    it "does not match salary_advance?, pay_advances, the contract or i18n" do
      [
        "@request.salary_advance?", "can?(:pay_advances)", "Requests::AdvanceEffects.advance_paid(request: r, paid_at: t)",
        "t(\"requests.advance.title\")"
      ].each { |code| expect(code.gsub(/"(?:[^"\\]|\\.)*"/, '""')).not_to match(boundary::ADVANCE_REF), code }
    end

    it "catches a Workforce callback planted in the implementation" do
      plant(boundary::IMPLEMENTATION, "request.update!(status: \"paid\")\nRequests::Canceller.cancel(request: r)\n")

      expect(boundary.matches_in(boundary::IMPLEMENTATION, boundary::WORKFORCE_CALLBACK).size).to eq(2)
    end
  end
end
