require "rails_helper"

# Boundary for Pilot 9 — Workforce Request Permission Payroll Effects (M3-A; see
# docs/architecture/next-pilot-selection.md §24). Focused on the approval route
# M3-A changed; M6 extends it to the whole flow (cancellation after M3-B / M4).
#
# Requests::Approver reaches the permission's payroll effect only through the
# Workforce contract Requests::PermissionPayrollEffects; it never names the
# Attendance & Payroll applier or the contract implementation. Attendance &
# Payroll keeps using its own code (Payroll::PermissionPayrollEffects →
# Payroll::PermissionApplier); the contract names nothing from it.
module ArchitectureSpecs
  module WorkforceRequestPermissionPayrollBoundary
    module_function

    APPROVER       = "app/services/requests/approver.rb".freeze
    CONTRACT_FILE  = "app/services/requests/permission_payroll_effects.rb".freeze
    IMPLEMENTATION = "app/services/payroll/permission_payroll_effects.rb".freeze

    FORBIDDEN_IN_APPROVER = /\bPermissionApplier\b|\bPayroll::PermissionPayrollEffects\b/

    # Full-line comments are ignored.
    def code_lines(path)
      File.read(Rails.root.join(path)).each_line.with_index(1)
          .reject { |line, _| line.lstrip.start_with?("#") }
    end

    def matches_in(path, pattern)
      code_lines(path).filter_map { |line, number| "#{path}:#{number}: #{line.strip}" if line.match?(pattern) }
    end
  end
end

RSpec.describe "Architecture: Workforce request permission payroll boundary (approval)" do
  boundary = ArchitectureSpecs::WorkforceRequestPermissionPayrollBoundary

  it "Requests::Approver does not name the Attendance & Payroll applier or the contract implementation" do
    violations = boundary.matches_in(boundary::APPROVER, boundary::FORBIDDEN_IN_APPROVER)
    expect(violations).to be_empty, <<~MSG
      Workforce approval must reach the permission's payroll effect through Requests::PermissionPayrollEffects:
      #{violations.join("\n")}
    MSG
  end

  it "Requests::Approver calls the contract's permission_approved exactly once" do
    calls = boundary.matches_in(boundary::APPROVER, /\bRequests::PermissionPayrollEffects\.\w+/)
    expect(calls.size).to eq(1)
    expect(calls.first).to include("Requests::PermissionPayrollEffects.permission_approved(request: @request)")
  end

  it "the contract names nothing from Attendance & Payroll; the implementation keeps using its own applier" do
    expect(boundary.matches_in(boundary::CONTRACT_FILE, /\bPayroll\b|\bAttendance::|\bSalary::/)).to be_empty
    expect(boundary.matches_in(boundary::IMPLEMENTATION, /\bPayroll::PermissionApplier\.call\b/)).not_to be_empty
  end

  describe "self-test (planted probe)" do
    it "catches the applier planted back into the approver" do
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(Rails.root.join(boundary::APPROVER))
                                   .and_return("Payroll::PermissionApplier.call(@request)\n# Payroll::PermissionApplier\n")

      expect(boundary.matches_in(boundary::APPROVER, boundary::FORBIDDEN_IN_APPROVER).size).to eq(1)
    end
  end
end
