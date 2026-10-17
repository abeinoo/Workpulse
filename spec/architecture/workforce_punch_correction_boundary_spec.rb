require "rails_helper"

# Boundary for Pilot 10 — Punch Correction (M2, M3; see
# docs/architecture/next-pilot-selection.md §25).
#
# M2 defined the Workforce contract Requests::PunchCorrectionEffects and its
# Attendance & Payroll implementation Attendance::PunchCorrectionEffects: the
# contract names nothing from Attendance & Payroll, the implementation never
# calls back into Workforce's request lifecycle or writes the request's own
# data, and the implementation is wired only by the composition root.
#
# M3 routed the read-only path: Requests::PunchCorrectionAssessment reads its
# attendance facts only through correction_facts and names nothing from
# Attendance & Payroll.
#
# M4-2 routed approval and cancellation together: Requests::PunchCorrectionApplier
# (called by Requests::Approver) reaches the attendance & payroll effect only
# through correction_approved, Requests::Canceller only through
# correction_cancelled.
#
# M6 removed what M4 had left unreachable: Requests::Canceller's pre-M4
# rollback and its helpers, and the pre-M4 payroll services
# Payroll::PunchCorrectionApplier / Payroll::PunchCorrectionReverter (the
# payroll effect is Payroll::EntryRecalculator since M4-3). They must stay gone,
# and the canceller names nothing from Attendance & Payroll.
module ArchitectureSpecs
  module WorkforcePunchCorrectionBoundary
    module_function

    CONTRACT_FILE   = "app/services/requests/punch_correction_effects.rb".freeze
    IMPLEMENTATION  = "app/services/attendance/punch_correction_effects.rb".freeze
    INITIALIZER     = "config/initializers/request_punch_correction_effects.rb".freeze
    ASSESSMENT      = "app/services/requests/punch_correction_assessment.rb".freeze
    APPLIER         = "app/services/requests/punch_correction_applier.rb".freeze
    APPROVER        = "app/services/requests/approver.rb".freeze
    CANCELLER       = "app/services/requests/canceller.rb".freeze

    # Removed in M6 — must not come back.
    REMOVED_FILES = %w[
      app/services/payroll/punch_correction_applier.rb
      app/services/payroll/punch_correction_reverter.rb
    ].freeze
    REMOVED_CONSTANTS = %w[Payroll::PunchCorrectionApplier Payroll::PunchCorrectionReverter].freeze
    REMOVED_CANCELLER_METHODS = %i[
      rollback_punch_correction rollback_punch_payroll restore_penalty_line_item
      covering_period daily_rate_for compute_penalty
    ].freeze
    REMOVED_NAMES = /\bPayroll::PunchCorrection(?:Applier|Reverter)\b|\brollback_punch_(?:correction|payroll)\b/

    # The contract, with or without its namespace (callers inside module Requests omit it).
    CONTRACT_NAME = /(?<![\w:])(?:Requests::)?PunchCorrectionEffects\b/

    # The write operations, routed in M4-2.
    WRITE_OPERATIONS = /\.correction_(?:approved|cancelled)\b/

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

  it "M3: the assessment names nothing from Attendance & Payroll" do
    violations = boundary.matches_in(boundary::ASSESSMENT, boundary::CONTRACT_FORBIDDEN)
    expect(violations).to be_empty, "Read attendance facts through correction_facts:\n#{violations.join("\n")}"
  end

  it "M4-2: the Workforce users of the contract are the assessment, the applier and the canceller, one operation each" do
    files = boundary.source_files.reject { |path| path.start_with?("app/services/attendance/") }
    users = files.select { |path| boundary.matches_in(path, boundary::CONTRACT_NAME).any? } - [ boundary::CONTRACT_FILE ]
    expect(users).to contain_exactly(boundary::ASSESSMENT, boundary::APPLIER, boundary::CANCELLER)

    { boundary::ASSESSMENT => %w[correction_facts], boundary::APPLIER => %w[correction_approved],
      boundary::CANCELLER => %w[correction_cancelled] }.each do |path, operations|
      calls = boundary.matches_in(path, /PunchCorrectionEffects\.\w+/)
      expect(calls.map { |line| line[/PunchCorrectionEffects\.(\w+)/, 1] }.uniq).to eq(operations), path
    end
  end

  it "M4-2: correction_approved is called only by the applier, correction_cancelled only by the canceller" do
    callers = boundary.source_files.flat_map { |path| boundary.matches_in(path, boundary::WRITE_OPERATIONS) }
                      .reject { |line| line.start_with?(boundary::CONTRACT_FILE, boundary::IMPLEMENTATION) }
    expect(callers.map { |line| [ line.split(":").first, line[/\.(correction_\w+)/, 1] ] }.uniq)
      .to contain_exactly([ boundary::APPLIER, "correction_approved" ], [ boundary::CANCELLER, "correction_cancelled" ])
  end

  it "M4-2: the approver and the applier name nothing from Attendance & Payroll" do
    violations = [ boundary::APPROVER, boundary::APPLIER ].flat_map { |path| boundary.matches_in(path, boundary::CONTRACT_FORBIDDEN) }
    expect(violations).to be_empty, "Reach attendance & payroll through correction_approved:\n#{violations.join("\n")}"
  end

  it "M6: the canceller names nothing from Attendance & Payroll (the whole file — no legacy section left)" do
    violations = boundary.matches_in(boundary::CANCELLER, boundary::CONTRACT_FORBIDDEN)
    expect(violations).to be_empty, "Reach attendance & payroll through correction_cancelled:\n#{violations.join("\n")}"
  end

  it "M6: the pre-M4 payroll services and the canceller's pre-M4 rollback are gone, and nothing names them" do
    expect(boundary::REMOVED_FILES.select { |file| File.exist?(Rails.root.join(file)) }).to be_empty
    boundary::REMOVED_CONSTANTS.each { |name| expect(Object.const_defined?(name)).to be(false), name }
    boundary::REMOVED_CANCELLER_METHODS.each do |name|
      expect(Requests::Canceller.private_method_defined?(name) || Requests::Canceller.method_defined?(name)).to be(false), name
    end

    named = (boundary.source_files + boundary.source_files("config")).flat_map { |path| boundary.matches_in(path, boundary::REMOVED_NAMES) }
    expect(named).to be_empty, named.join("\n")
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

    it "catches Attendance & Payroll reads planted back into the assessment" do
      plant(boundary::ASSESSMENT, "@window = Attendance::PunchWindow.for(user: u, work_date: d)\n" \
                                  "@record = AttendanceRecord.find_by(user: u)\n")
      expect(boundary.matches_in(boundary::ASSESSMENT, boundary::CONTRACT_FORBIDDEN).size).to eq(2)
    end

    it "catches an early approval / cancellation route (bare or namespaced) and a bare contract use" do
      plant("app/services/requests/approver.rb", "PunchCorrectionEffects.correction_approved(request: @request)\n" \
                                                 "Requests::PunchCorrectionEffects.correction_cancelled(request: r)\n")
      expect(boundary.matches_in("app/services/requests/approver.rb", boundary::WRITE_OPERATIONS).size).to eq(2)
      expect(boundary.matches_in("app/services/requests/approver.rb", boundary::CONTRACT_NAME).size).to eq(2)
    end

    it "catches Attendance & Payroll names planted in the approver, the applier or the canceller's live code" do
      plant(boundary::APPROVER, "record = AttendanceRecord.find_by(user: u)\n")
      plant(boundary::APPLIER, "Payroll::PunchCorrectionApplier.call(request: @request, record: record)\n")
      expect([ boundary::APPROVER, boundary::APPLIER ].flat_map { |p| boundary.matches_in(p, boundary::CONTRACT_FORBIDDEN) }.size)
        .to eq(2)

      plant(boundary::CANCELLER, "def cancel\n  Attendance::RecordRecomputer.recompute!(record)\nend\n" \
                                 "def rollback_punch_correction\n  PayrollEntry.first\nend\n")
      expect(boundary.matches_in(boundary::CANCELLER, boundary::CONTRACT_FORBIDDEN).size).to eq(2) # no exempt section any more
    end

    it "catches a removed service or the legacy rollback planted back" do
      plant(boundary::CANCELLER, "def rollback_punch_payroll(record)\nend\n")
      plant(boundary::IMPLEMENTATION, "Payroll::PunchCorrectionReverter.call(request: request, record: record, period: period)\n")
      expect([ boundary::CANCELLER, boundary::IMPLEMENTATION ].flat_map { |p| boundary.matches_in(p, boundary::REMOVED_NAMES) }.size)
        .to eq(2)
    end

    it "lets the implementation name the contract's value types" do
      plant(boundary::IMPLEMENTATION, "Requests::PunchCorrectionEffects::Facts.new(record_found: true)\n" \
                                      "Requests::PunchCorrectionEffects::Snapshot.new(check_in_at: record.check_in_at)\n")
      expect(boundary.matches_in(boundary::IMPLEMENTATION, boundary::WORKFORCE_CALLBACK)).to be_empty
    end
  end
end
