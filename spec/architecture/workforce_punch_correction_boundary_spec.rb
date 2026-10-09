require "rails_helper"

# Boundary for Pilot 10 — Punch Correction (M2; see
# docs/architecture/next-pilot-selection.md §25).
#
# M2 defines the Workforce contract Requests::PunchCorrectionEffects and its
# Attendance & Payroll implementation Attendance::PunchCorrectionEffects. This
# spec pins the contract side only: the contract names nothing from Attendance &
# Payroll, the implementation never calls back into Workforce's request
# lifecycle or writes the request's own data, and the implementation is wired
# only by the composition root. Routing the callers (Requests::Approver,
# Requests::Canceller, Requests::PunchCorrectionAssessment) is M3; their
# boundary is added in M6.
module ArchitectureSpecs
  module WorkforcePunchCorrectionBoundary
    module_function

    CONTRACT_FILE   = "app/services/requests/punch_correction_effects.rb".freeze
    IMPLEMENTATION  = "app/services/attendance/punch_correction_effects.rb".freeze
    INITIALIZER     = "config/initializers/request_punch_correction_effects.rb".freeze

    CONTRACT_FORBIDDEN = /\bPayroll\b|\b(?:Attendance|Salary|Shifts)::|\b(?:PayrollPeriod|PayrollEntry|PayrollLineItem|AttendanceRecord)\b/

    # Attendance & Payroll may name the contract it implements (its value types),
    # nothing else of Workforce's request lifecycle: no other Requests:: service,
    # no EmployeeRequest constant, no lifecycle call, no status write, no write of
    # the request's snapshot / approved moment, no request audit.
    WORKFORCE_CALLBACK = /
      \bRequests::(?!PunchCorrectionEffects\b)\w+
      | \bEmployeeRequest\b
      | \.(?:approve|reject|cancel|pay)[!(\s]
      | \bupdate(?:_columns|_column|!)?\(\s*:?status\b | \bstatus\s*=(?!=)
      | \b(?:approved_punch_at|original_check_(?:in|out)_(?:at|source))\s*(?:=(?!=)|:)
      | \blog_audit\b | \bAuditLog\b
    /x

    def code_lines(path)
      File.read(Rails.root.join(path)).each_line.with_index(1)
          .reject { |line, _| line.lstrip.start_with?("#") }
    end

    def matches_in(path, pattern)
      code_lines(path).filter_map { |line, number| "#{path}:#{number}: #{line.strip}" if line.match?(pattern) }
    end

    def source_files(root = "{app,lib}")
      Dir.glob(Rails.root.join("#{root}/**/*.{rb,erb,rake}")).map { |f| f.delete_prefix("#{Rails.root}/") }
    end
  end
end

RSpec.describe "Architecture: Workforce punch correction boundary (contract)" do
  boundary = ArchitectureSpecs::WorkforcePunchCorrectionBoundary

  it "the contract names nothing from Attendance & Payroll" do
    violations = boundary.matches_in(boundary::CONTRACT_FILE, boundary::CONTRACT_FORBIDDEN)
    expect(violations).to be_empty, violations.join("\n")
  end

  it "the implementation never calls back into Workforce or writes the request, its snapshot or its audit" do
    callbacks = boundary.matches_in(boundary::IMPLEMENTATION, boundary::WORKFORCE_CALLBACK)
    expect(callbacks).to be_empty, "Attendance & Payroll must not call Workforce:\n#{callbacks.join("\n")}"
  end

  it "the implementation is named only by itself and the composition root" do
    files  = boundary.source_files + boundary.source_files("config")
    namers = files.select { |path| boundary.matches_in(path, /\bAttendance::PunchCorrectionEffects\b/).any? }
    expect(namers - [ boundary::IMPLEMENTATION, boundary::INITIALIZER ]).to be_empty
  end

  it "no caller is routed through the contract yet (M3)" do
    namers = boundary.source_files.select { |path| boundary.matches_in(path, /\bRequests::PunchCorrectionEffects\b/).any? }
    expect(namers - [ boundary::CONTRACT_FILE, boundary::IMPLEMENTATION ]).to be_empty
  end

  describe "self-tests (planted probes)" do
    def plant(path, content)
      unless @reads_stubbed
        allow(File).to receive(:read).and_call_original
        @reads_stubbed = true
      end
      allow(File).to receive(:read).with(Rails.root.join(path)).and_return(content)
    end

    it "catches Attendance & Payroll names planted in the contract" do
      plant(boundary::CONTRACT_FILE, "Payroll::PunchCorrectionApplier.call(request)\nAttendanceRecord.first\n" \
                                     "Attendance::RecordRecomputer.recompute!(r)\nShifts::AssignmentResolver.for(user: u, date: d)\n")
      expect(boundary.matches_in(boundary::CONTRACT_FILE, boundary::CONTRACT_FORBIDDEN).size).to eq(4)
    end

    it "catches Workforce callbacks and request writes planted in the implementation" do
      plant(boundary::IMPLEMENTATION, <<~RUBY)
        Requests::PunchCorrectionApplier.call(request: request)
        Requests::Canceller.cancel(request: request, cancelled_by: nil, reason: nil)
        EmployeeRequest.find(1)
        request.update!(status: "approved")
        request.update_columns(original_check_in_at: record.check_in_at)
        request.approved_punch_at = effective_at
        log_audit(actor: nil, auditable: request, action: "approve")
        AuditLog.create!
      RUBY
      expect(boundary.matches_in(boundary::IMPLEMENTATION, boundary::WORKFORCE_CALLBACK).size).to eq(8)
    end

    it "lets the implementation name the contract's value types" do
      plant(boundary::IMPLEMENTATION, "Requests::PunchCorrectionEffects::Facts.new(record_found: true)\n" \
                                      "Requests::PunchCorrectionEffects::Snapshot.new(check_in_at: record.check_in_at)\n")
      expect(boundary.matches_in(boundary::IMPLEMENTATION, boundary::WORKFORCE_CALLBACK)).to be_empty
    end
  end
end
