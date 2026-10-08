require "rails_helper"

# Boundary for Pilot 9 — Workforce Request Permission Payroll Effects (M3-A,
# M3-B + M4; see docs/architecture/next-pilot-selection.md §24). M6 completes it.
#
# Workforce (Requests::Approver, Requests::Canceller) reaches the payroll effect
# of a late / early-leave permission only through the Workforce contract
# Requests::PermissionPayrollEffects; Attendance & Payroll implements it
# (Payroll::PermissionPayrollEffects → PermissionApplier / PermissionReverter)
# and never calls back into Workforce request services. One-way.
#
# Requests::Canceller still names Attendance & Payroll in its PUNCH-CORRECTION
# rollback (out of this pilot; module-boundaries.md §14.2 #3): those references
# are allowed only inside the punch-correction methods listed below, so they
# cannot spread back into the permission path.
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

    # The punch-correction rollback and the helpers it (alone, since M4) uses.
    PUNCH_CORRECTION_METHODS = %w[
      rollback_punch_correction rollback_punch_payroll restore_penalty_line_item
      covering_period daily_rate_for compute_penalty
    ].freeze

    # Attendance & Payroll must not call back into Workforce's request lifecycle.
    WORKFORCE_CALLBACK = /\bRequests::\w+|\.(?:approve|reject|cancel|pay)[!(\s]|\bupdate!?\(\s*status:/

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

    # Attendance & Payroll names in the canceller OUTSIDE the punch-correction methods.
    def canceller_leaks
      owners = method_of_line(CANCELLER)
      code_lines(CANCELLER).filter_map do |line, number|
        next unless line.match?(ATTENDANCE_PAYROLL)
        next if PUNCH_CORRECTION_METHODS.include?(owners[number])

        "#{CANCELLER}:#{number} (#{owners[number] || 'class body'}): #{line.strip}"
      end
    end

    def source_files
      Dir.glob(Rails.root.join("{app,lib}/**/*.{rb,erb,rake}")).map { |f| f.delete_prefix("#{Rails.root}/") }
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

    it "A. the canceller names Attendance & Payroll only inside the punch-correction rollback (not in the permission path)" do
      leaks = boundary.canceller_leaks
      expect(leaks).to be_empty, <<~MSG
        Requests::Canceller may name Attendance & Payroll only in #{boundary::PUNCH_CORRECTION_METHODS.join(', ')}:
        #{leaks.join("\n")}
      MSG
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

    it "the contract names nothing from Attendance & Payroll" do
      expect(boundary.matches_in(boundary::CONTRACT_FILE, /\bPayroll\b|\bAttendance::|\bSalary::/)).to be_empty
    end
  end

  it "E. the temporary M2 bridge and the old rollback are gone from the code" do
    leftovers = boundary.source_files.flat_map { |path| boundary.matches_in(path, boundary::REMOVED) }
    expect(leftovers).to be_empty, leftovers.join("\n")
    expect(Requests::Canceller).not_to respond_to(:revert_permission_payroll)
    expect(Requests::Canceller.private_method_defined?(:rollback_permission)).to be(false)
    expect(defined?(Requests::Canceller::PermissionRevertFailed)).to be_nil
  end

  it "F. the punch-correction rollback and its helpers are still in place" do
    boundary::PUNCH_CORRECTION_METHODS.each do |name|
      expect(Requests::Canceller.private_method_defined?(name.to_sym)).to be(true), name
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

    it "catches payroll models planted in the canceller's permission path but not in the punch rollback" do
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
      expect(boundary.canceller_leaks).to eq([ "#{boundary::CANCELLER}:4 (revert_permission_payroll_effect): PayrollEntry.find_by(user: @request.user)" ])
    end

    it "catches a Workforce callback planted in the Attendance & Payroll implementation" do
      plant("app/services/payroll/permission_reverter.rb", "Requests::Canceller.cancel(request: request, cancelled_by: nil, reason: nil)\n" \
                                                            "request.update!(status: \"cancelled\")\n")
      expect(boundary.matches_in("app/services/payroll/permission_reverter.rb", boundary::WORKFORCE_CALLBACK).size).to eq(2)
    end

    it "catches the bridge planted back" do
      plant("app/services/payroll/permission_payroll_effects.rb", "Requests::Canceller.revert_permission_payroll(request)\n")
      expect(boundary.matches_in("app/services/payroll/permission_payroll_effects.rb", boundary::REMOVED)).not_to be_empty
    end
  end
end
