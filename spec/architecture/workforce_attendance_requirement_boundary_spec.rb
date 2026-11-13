require "rails_helper"

# Boundary enforcement for R3.2 — the attendance requirement history and the
# Employment Start Date (roadmap revision 19, §2 W, §19.14).
#
# The history and the start date are Workforce data; payroll periods, their
# status and the payroll-status lock are owned by Attendance & Payroll,
# downstream of Workforce. Workforce asks "does a protected payroll period
# overlap these dates?" only through its own contract
# Employee::PayrollDateProtection, implemented by
# Payroll::RequirementDateProtection and wired in
# config/initializers/employee_payroll_date_protection.rb (OD-1).
#
# Rules:
# 1. Workforce R3.2 code never names Attendance & Payroll: no Payroll:: /
#    Attendance:: constant, no PayrollPeriod / PayrollEntry, no payroll_periods
#    association or table, and no payroll status name (the contract speaks in
#    Workforce stages).
# 2. The implementation is named only by the composition root (and itself).
# 3. The payroll-status lock is named only inside Attendance & Payroll.
#
# WORKFORCE_FILES grows with each R3.2 gate; every entry must exist (no stale
# entries). Comments and i18n keys are ignored, as in the other boundary specs.
module ArchitectureSpecs
  module WorkforceAttendanceRequirementBoundary
    module_function

    CONTRACT         = "Employee::PayrollDateProtection".freeze
    IMPLEMENTATION   = "Payroll::RequirementDateProtection".freeze
    STATUS_LOCK      = "Payroll::StatusLock".freeze
    COMPOSITION_ROOT = "config/initializers/employee_payroll_date_protection.rb".freeze

    WORKFORCE_FILES = {
      "app/services/employee/payroll_date_protection.rb" => "the Workforce contract (G3)"
    }.freeze

    FORBIDDEN_IN_WORKFORCE = /
      \bPayroll::\w+
      | \bAttendance::\w+
      | \b(?:PayrollPeriod|PayrollEntry|PayrollPeriodBranchReview)\b
      | \bpayroll_(?:periods|entries)\b
      | \b(?:under_review|branch_review_completed)\b
    /x

    # Attendance & Payroll files that may name the payroll-status lock.
    STATUS_LOCK_FILES = %w[
      app/services/payroll/status_lock.rb
      app/services/payroll/requirement_date_protection.rb
      app/services/payroll/submit_for_review.rb
    ].freeze

    def source_files
      Dir.glob(Rails.root.join("{app,lib,config}/**/*.{rb,erb,rake}")).map { |f| f.delete_prefix("#{Rails.root}/") }.sort
    end

    def code_lines(path)
      File.read(Rails.root.join(path)).each_line.with_index(1)
          .reject { |line, _| line.lstrip.start_with?("#") }
          .map { |line, number| [ line.gsub(/\b(?:I18n\.)?t\(\s*(["'])[^"']*\1/, 't("KEY"'), number ] }
    end

    def matches_in(path, pattern)
      code_lines(path).filter_map { |line, number| "#{path}:#{number}: #{line.strip}" if line.match?(pattern) }
    end
  end
end

RSpec.describe "Workforce attendance requirement boundary (R3.2)" do
  boundary = ArchitectureSpecs::WorkforceAttendanceRequirementBoundary

  it "lists only Workforce files that exist (no stale entries)" do
    missing = boundary::WORKFORCE_FILES.keys.reject { |path| File.exist?(Rails.root.join(path)) }
    expect(missing).to be_empty
  end

  it "keeps Attendance & Payroll out of Workforce R3.2 code" do
    offenders = boundary::WORKFORCE_FILES.keys.flat_map { |path| boundary.matches_in(path, boundary::FORBIDDEN_IN_WORKFORCE) }
    expect(offenders).to be_empty, "Workforce R3.2 code names Attendance & Payroll:\n#{offenders.join("\n")}"
  end

  it "names the implementation only in the composition root" do
    pattern   = /\b#{Regexp.escape(boundary::IMPLEMENTATION)}\b/
    allowed   = [ boundary::COMPOSITION_ROOT, "app/services/payroll/requirement_date_protection.rb" ]
    offenders = (boundary.source_files - allowed).flat_map { |path| boundary.matches_in(path, pattern) }
    expect(offenders).to be_empty, "#{boundary::IMPLEMENTATION} named outside the composition root:\n#{offenders.join("\n")}"
    expect(boundary.matches_in(boundary::COMPOSITION_ROOT, pattern)).not_to be_empty
  end

  it "names the payroll-status lock only inside Attendance & Payroll" do
    pattern   = /\b#{Regexp.escape(boundary::STATUS_LOCK)}\b/
    offenders = (boundary.source_files - boundary::STATUS_LOCK_FILES).flat_map { |path| boundary.matches_in(path, pattern) }
    expect(offenders).to be_empty, "#{boundary::STATUS_LOCK} named outside Attendance & Payroll:\n#{offenders.join("\n")}"
  end

  it "registers the implementation for the Workforce contract" do
    expect(Employee::PayrollDateProtection.handler).to eq(Payroll::RequirementDateProtection)
  end

  describe "planted probes" do
    it "catches every forbidden shape in Workforce code" do
      [ "Payroll::RequirementDateProtection.lock_protected_range(**args)", "PayrollPeriod.where(business_id: id)",
        "user.payroll_entries.exists?", "period.status == \"under_review\"", "Attendance::PunchService.call",
        "Payroll::StatusLock.shared!(business_id: id)" ].each do |line|
        expect(line).to match(boundary::FORBIDDEN_IN_WORKFORCE), "probe not caught: #{line}"
      end
    end

    it "allows the Workforce contract and its stages" do
      [ "Employee::PayrollDateProtection.lock_protected_range(business_id: id, from: a, through: b)",
        "answer.stage == :in_review", "STAGES = %i[in_review finalized].freeze" ].each do |line|
        expect(line).not_to match(boundary::FORBIDDEN_IN_WORKFORCE), "false positive: #{line}"
      end
    end
  end
end
