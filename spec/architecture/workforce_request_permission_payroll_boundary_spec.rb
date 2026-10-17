require "rails_helper"

# Boundary for Pilot 9 — Workforce Request Permission Payroll Effects (M3-A,
# M3-B + M4, completed in M6; see docs/architecture/next-pilot-selection.md §24).
#
# Workforce (Requests::Approver, Requests::Canceller) reaches the payroll effect
# of a late / early-leave permission only through the Workforce contract
# Requests::PermissionPayrollEffects; Attendance & Payroll implements it
# (Payroll::PermissionPayrollEffects → PermissionApplier / PermissionReverter)
# and never calls back into Workforce request services. One-way.
#
# Requests::Canceller used to name Attendance & Payroll in its PUNCH-CORRECTION
# rollback (out of this pilot; module-boundaries.md §14.2 #3), allowed only
# inside the punch-correction methods listed below. Pilot 10 routed that effect
# through Requests::PunchCorrectionEffects (M4) and removed the rollback (M6):
# the canceller now names Attendance & Payroll nowhere.
module ArchitectureSpecs
  module WorkforceRequestPermissionPayrollBoundary
    module_function

    APPROVER       = "app/services/requests/approver.rb".freeze
    CANCELLER      = "app/services/requests/canceller.rb".freeze
    CONTRACT_FILE  = "app/services/requests/permission_payroll_effects.rb".freeze
    IMPLEMENTATION = %w[
      app/services/payroll/permission_payroll_effects.rb
      app/services/payroll/permission_reverter.rb
      app/services/payroll/permission_applier.rb
    ].freeze

    # The permission's payroll internals — never in a Workforce caller.
    PERMISSION_INTERNALS = /\b(?:PermissionApplier|PermissionReverter|Payroll::PermissionPayrollEffects)\b/

    # Any Attendance & Payroll name (models, calculators, services).
    ATTENDANCE_PAYROLL = /
      \b(?:Payroll|Attendance|Salary)::\w+
      | \b(?:PayrollPeriod|PayrollEntry|PayrollLineItem|AttendanceRecord)\b
    /x

    # The canceller's pre-Pilot-10 punch-correction rollback and its helpers — the
    # only place the canceller was allowed to name Attendance & Payroll. Removed in
    # Pilot 10 M6 (the punch effect goes through Requests::PunchCorrectionEffects),
    # so the exception is gone and these must not come back.
    PUNCH_CORRECTION_METHODS = %w[
      rollback_punch_correction rollback_punch_payroll restore_penalty_line_item
      covering_period daily_rate_for compute_penalty
    ].freeze

    # The permission path inside the Workforce callers (methods introduced or
    # routed by this pilot). Nothing from Attendance & Payroll may appear here.
    PERMISSION_PATH = {
      APPROVER  => %w[approve_standard],
      CANCELLER => %w[cancel rollback_approval_effects revert_permission_payroll_effect]
    }.freeze

    # The forbidden list of the permission path (any Attendance & Payroll constant
    # is covered by ATTENDANCE_PAYROLL; these are named for the record).
    PERMISSION_PATH_FORBIDDEN = /
      \b(?:Payroll::PermissionApplier|Payroll::PermissionReverter|Payroll::PermissionPayrollEffects
        |PayrollPeriod|PayrollEntry|PayrollLineItem|AttendanceRecord
        |Attendance::PenaltyCalculator|Salary::DailyRateCalculator|Attendance::RecordRecomputer)\b
      | \b(?:Payroll|Attendance|Salary)::\w+
    /x

    # Where the permission classes may be named at all (app/, lib/, config/).
    PERMISSION_CLASS_NAMERS = {
      /\bRequests::PermissionPayrollEffects\b/ => [ APPROVER, CANCELLER, CONTRACT_FILE,
                                                    "config/initializers/request_permission_payroll_effects.rb" ],
      /\bPayroll::PermissionPayrollEffects\b/  => [ "app/services/payroll/permission_payroll_effects.rb",
                                                    "config/initializers/request_permission_payroll_effects.rb" ],
      /\bPayroll::PermissionApplier\b/         => [ "app/services/payroll/permission_payroll_effects.rb" ],
      /\bPayroll::PermissionReverter\b/        => [ "app/services/payroll/permission_payroll_effects.rb" ]
    }.freeze

    # Attendance & Payroll must not call back into Workforce's request lifecycle:
    # no Requests:: service, no EmployeeRequest constant, no lifecycle call, no
    # status write. (Reading the request it is handed — user, type predicates,
    # dates, minutes — is the contract.)
    WORKFORCE_CALLBACK = /\bRequests::\w+|\bEmployeeRequest\b|\.(?:approve|reject|cancel|pay)[!(\s]|\bupdate!?\(\s*status:|\bstatus\s*=(?!=)/

    CONTRACT_FORBIDDEN = /\bPayroll\b|\b(?:Attendance|Salary)::|\b(?:PayrollPeriod|PayrollEntry|PayrollLineItem|AttendanceRecord)\b/

    REMOVED = /\b(?:revert_permission_payroll|PermissionRevertFailed|rollback_permission)\b/

    # Full-line comments are ignored.
    def code_lines(path)
      File.read(Rails.root.join(path)).each_line.with_index(1)
          .reject { |line, _| line.lstrip.start_with?("#") }
    end

    def matches_in(path, pattern)
      code_lines(path).filter_map { |line, number| "#{path}:#{number}: #{line.strip}" if line.match?(pattern) }
    end

    # line number → name of the enclosing method (4-space-indented defs).
    def method_of_line(path)
      current = nil
      File.read(Rails.root.join(path)).each_line.with_index(1).to_h do |line, number|
        current = Regexp.last_match(1) if line =~ /\A    def (?:self\.)?(\w+[?!]?)/
        [ number, current ]
      end
    end

    # Attendance & Payroll names anywhere in the canceller (no exempt methods since
    # Pilot 10 M6).
    def canceller_leaks
      owners = method_of_line(CANCELLER)
      code_lines(CANCELLER).filter_map do |line, number|
        next unless line.match?(ATTENDANCE_PAYROLL)

        "#{CANCELLER}:#{number} (#{owners[number] || 'class body'}): #{line.strip}"
      end
    end

    def permission_path_violations
      PERMISSION_PATH.flat_map do |path, methods|
        owners = method_of_line(path)
        code_lines(path).filter_map do |line, number|
          next unless methods.include?(owners[number]) && line.match?(PERMISSION_PATH_FORBIDDEN)

          "#{path}:#{number} (#{owners[number]}): #{line.strip}"
        end
      end
    end

    def source_files(root = "{app,lib}")
      Dir.glob(Rails.root.join("#{root}/**/*.{rb,erb,rake}")).map { |f| f.delete_prefix("#{Rails.root}/") }
    end
  end
end

RSpec.describe "Architecture: Workforce request permission payroll boundary" do
  boundary = ArchitectureSpecs::WorkforceRequestPermissionPayrollBoundary

  describe "Workforce callers" do
    it "A. neither caller names the permission's payroll internals (applier, reverter, implementation)" do
      violations = [ boundary::APPROVER, boundary::CANCELLER ].flat_map { |path| boundary.matches_in(path, boundary::PERMISSION_INTERNALS) }
      expect(violations).to be_empty, "Go through Requests::PermissionPayrollEffects:\n#{violations.join("\n")}"
    end

    it "A. the canceller names Attendance & Payroll nowhere (the punch-correction exception was removed in Pilot 10 M6)" do
      leaks = boundary.canceller_leaks
      expect(leaks).to be_empty, <<~MSG
        Requests::Canceller must reach Attendance & Payroll only through the Workforce contracts:
        #{leaks.join("\n")}
      MSG
    end

    it "A. the permission path (approve_standard; cancel, rollback_approval_effects, revert_permission_payroll_effect) names nothing from Attendance & Payroll" do
      violations = boundary.permission_path_violations
      expect(violations).to be_empty, "The permission path must go through Requests::PermissionPayrollEffects:\n#{violations.join("\n")}"

      found = boundary::PERMISSION_PATH.flat_map { |path, methods| methods.map { |m| [ path, m ] } }
                                       .reject { |path, m| boundary.method_of_line(path).value?(m) }
      expect(found).to be_empty, "Permission-path methods no longer found: #{found.inspect}"
    end

    it "A. the approver names no permission payroll internals and no payroll model" do
      expect(boundary.matches_in(boundary::APPROVER, /\b(?:PayrollPeriod|PayrollEntry|PayrollLineItem|AttendanceRecord)\b|\b(?:Salary|Attendance)::/)).to be_empty
    end

    it "B. each caller uses the contract once, for its own operation" do
      { boundary::APPROVER => "permission_approved", boundary::CANCELLER => "permission_cancelled" }.each do |path, operation|
        calls = boundary.matches_in(path, /\bRequests::PermissionPayrollEffects\.\w+/)
        expect(calls.size).to eq(1), "#{path}: #{calls.inspect}"
        expect(calls.first).to include("Requests::PermissionPayrollEffects.#{operation}(request: @request)")
      end
    end
  end

  describe "Attendance & Payroll implementation" do
    it "C. may use its own payroll models and calculators (the reverter does)" do
      expect(boundary.matches_in("app/services/payroll/permission_reverter.rb", boundary::ATTENDANCE_PAYROLL)).not_to be_empty
    end

    it "D. never calls back into Workforce request services or lifecycle methods" do
      callbacks = boundary::IMPLEMENTATION.flat_map { |path| boundary.matches_in(path, boundary::WORKFORCE_CALLBACK) }
      expect(callbacks).to be_empty, "Attendance & Payroll must not call Workforce:\n#{callbacks.join("\n")}"
    end

    it "the contract names nothing from Attendance & Payroll (no Payroll / Attendance / Salary, no payroll or attendance model)" do
      expect(boundary.matches_in(boundary::CONTRACT_FILE, boundary::CONTRACT_FORBIDDEN)).to be_empty
    end

    it "the permission classes are named only by the callers, the contract, the implementation and the composition root" do
      files = boundary.source_files + boundary.source_files("config")
      boundary::PERMISSION_CLASS_NAMERS.each do |pattern, allowed|
        namers = files.select { |path| boundary.matches_in(path, pattern).any? } - [ boundary::CONTRACT_FILE ] -
                 %w[app/services/payroll/permission_applier.rb app/services/payroll/permission_reverter.rb]
        expect(namers - allowed).to be_empty, "#{pattern.source} named in: #{(namers - allowed).join(', ')}"
      end
    end
  end

  it "E. the temporary M2 bridge and the old rollback are gone from the code" do
    leftovers = boundary.source_files.flat_map { |path| boundary.matches_in(path, boundary::REMOVED) }
    expect(leftovers).to be_empty, leftovers.join("\n")
    expect(Requests::Canceller).not_to respond_to(:revert_permission_payroll)
    expect(Requests::Canceller.private_method_defined?(:rollback_permission)).to be(false)
    expect(defined?(Requests::Canceller::PermissionRevertFailed)).to be_nil
  end

  # Until Pilot 10 M6 this asserted the opposite (the legacy rollback was still
  # in place, the only allowed Attendance & Payroll use in the canceller).
  it "F. the canceller's pre-Pilot-10 punch-correction rollback and its helpers are gone" do
    boundary::PUNCH_CORRECTION_METHODS.each do |name|
      expect(Requests::Canceller.private_method_defined?(name.to_sym)).to be(false), name
    end
  end

  describe "self-tests (planted probes)" do
    def plant(path, content)
      unless @reads_stubbed
        allow(File).to receive(:read).and_call_original
        @reads_stubbed = true
      end
      allow(File).to receive(:read).with(Rails.root.join(path)).and_return(content)
    end

    it "catches the applier or reverter planted back into a Workforce caller" do
      plant(boundary::CANCELLER, "Payroll::PermissionReverter.call(@request)\n")
      plant(boundary::APPROVER, "Payroll::PermissionApplier.call(@request)\n")
      expect(boundary.matches_in(boundary::CANCELLER, boundary::PERMISSION_INTERNALS)).not_to be_empty
      expect(boundary.matches_in(boundary::APPROVER, boundary::PERMISSION_INTERNALS)).not_to be_empty
    end

    it "catches payroll models planted in the canceller's permission path and in a revived punch rollback" do
      plant(boundary::CANCELLER, <<~RUBY)
        module Requests
          class Canceller
            def revert_permission_payroll_effect
              PayrollEntry.find_by(user: @request.user)
            end

            def rollback_punch_payroll(record)
              PayrollEntry.find_by(user: @request.user)
            end
          end
        end
      RUBY
      expect(boundary.canceller_leaks).to eq([ "#{boundary::CANCELLER}:4 (revert_permission_payroll_effect): PayrollEntry.find_by(user: @request.user)",
                                               "#{boundary::CANCELLER}:8 (rollback_punch_payroll): PayrollEntry.find_by(user: @request.user)" ])
    end

    it "catches a Workforce callback planted in the Attendance & Payroll implementation" do
      plant("app/services/payroll/permission_reverter.rb", "Requests::Canceller.cancel(request: request, cancelled_by: nil, reason: nil)\n" \
                                                            "request.update!(status: \"cancelled\")\n")
      expect(boundary.matches_in("app/services/payroll/permission_reverter.rb", boundary::WORKFORCE_CALLBACK).size).to eq(2)
    end

    describe "the eight M6 probes" do
      cancel_with = ->(body) { "module Requests\n  class Canceller\n    def revert_permission_payroll_effect\n      #{body}\n    end\n  end\nend\n" }

      it "1. PermissionApplier in the approver" do
        plant(boundary::APPROVER, "    def approve_standard\n      Payroll::PermissionApplier.call(@request)\n    end\n")
        expect(boundary.permission_path_violations).not_to be_empty
        expect(boundary.matches_in(boundary::APPROVER, boundary::PERMISSION_INTERNALS)).not_to be_empty
      end

      it "2. PermissionReverter in the canceller" do
        plant(boundary::CANCELLER, cancel_with.call("Payroll::PermissionReverter.call(@request)"))
        expect(boundary.permission_path_violations).not_to be_empty
        expect(boundary.matches_in(boundary::CANCELLER, boundary::PERMISSION_INTERNALS)).not_to be_empty
      end

      {
        "3. PayrollPeriod"   => "PayrollPeriod.find_by(business: @request.user.business)",
        "4. PayrollLineItem" => "PayrollLineItem.where(source_id: 1).destroy_all",
        "5. AttendanceRecord" => "AttendanceRecord.find_by(user: @request.user)"
      }.each do |label, code|
        it "#{label} in permission-specific Workforce code" do
          plant(boundary::CANCELLER, cancel_with.call(code))
          expect(boundary.permission_path_violations).to include(a_string_including("(revert_permission_payroll_effect)"))
          expect(boundary.canceller_leaks).not_to be_empty
        end
      end

      it "6. the Attendance & Payroll implementation referencing Requests::Canceller" do
        plant("app/services/payroll/permission_payroll_effects.rb", "Requests::Canceller.new(request: request, cancelled_by: nil, reason: nil)\n")
        expect(boundary.matches_in("app/services/payroll/permission_payroll_effects.rb", boundary::WORKFORCE_CALLBACK)).not_to be_empty
      end

      it "7. the Attendance & Payroll implementation mutating the request lifecycle" do
        plant("app/services/payroll/permission_reverter.rb", "request.update!(status: \"cancelled\")\nrequest.status = \"approved\"\nEmployeeRequest.find(1)\n")
        expect(boundary.matches_in("app/services/payroll/permission_reverter.rb", boundary::WORKFORCE_CALLBACK).size).to eq(3)
      end

      it "8. the contract referencing Payroll::" do
        plant(boundary::CONTRACT_FILE, "Payroll::PermissionApplier.call(request)\nPayrollEntry.first\n")
        expect(boundary.matches_in(boundary::CONTRACT_FILE, boundary::CONTRACT_FORBIDDEN).size).to eq(2)
      end

      it "a revived punch-correction rollback is not a permission-path violation, but it is a canceller leak (Pilot 10 M6)" do
        plant(boundary::CANCELLER, "module Requests\n  class Canceller\n    def rollback_punch_payroll(record)\n      PayrollEntry.find_by(user: 1)\n    end\n  end\nend\n")
        expect(boundary.permission_path_violations.grep(/\A#{Regexp.escape(boundary::CANCELLER)}/)).to be_empty
        expect(boundary.canceller_leaks).to eq([ "#{boundary::CANCELLER}:4 (rollback_punch_payroll): PayrollEntry.find_by(user: 1)" ])
      end
    end

    it "catches the bridge planted back" do
      plant("app/services/payroll/permission_payroll_effects.rb", "Requests::Canceller.revert_permission_payroll(request)\n")
      expect(boundary.matches_in("app/services/payroll/permission_payroll_effects.rb", boundary::REMOVED)).not_to be_empty
    end
  end
end
