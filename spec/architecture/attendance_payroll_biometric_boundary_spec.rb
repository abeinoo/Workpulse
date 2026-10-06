require "rails_helper"

# Boundary enforcement for Milestone 2 Pilot 1 — Biometric Device + PunchService
# (Attendance & Payroll, M6; see docs/architecture/next-pilot-selection.md,
# "Milestone 2 — Attendance & Payroll" §7 and §14).
#
# BiometricDevice, BiometricPunchLog, Attendance::PunchService and
# Attendance::TimestampParser are owned by Attendance & Payroll (Q-M2-1/Q-M2-2).
# M0 found no cross-domain business caller, so there is NO boundary object:
# Attendance & Payroll code uses them directly, and other domains must not reach
# their internals (the classes, the services, or the `biometric_devices` /
# `biometric_punch_logs` collections and tables).
#
# Not guarded: the attendance-channel flags on users (allow_biometric_attendance),
# the "biometric_device" check-in source string, route helpers and policies
# (BiometricDevicePolicy), and config/ (routes, locales).
#
# This spec fails on any NEW direct reference outside the allow-list below.
# Adding to the allow-list is an architectural decision: give the reason.
module ArchitectureSpecs
  module AttendancePayrollBiometricBoundary
    module_function

    FORBIDDEN = /
      \bBiometricDevice\b          # the model and its class methods (not BiometricDevicePolicy)
      | \bBiometricPunchLog\b      # the model and its class methods
      | \bbiometric_devices\b      # the collection and table
      | \bbiometric_punch_logs\b   # the collection and table
      | \bPunchService\b           # Attendance::PunchService
      | \bTimestampParser\b        # Attendance::TimestampParser
    /x

    # Attendance & Payroll-owned code (module-boundaries.md §6): uses Pilot 1 directly.
    ATTENDANCE_PAYROLL_FILES = {
      "app/models/biometric_device.rb"                         => "the model itself (moves to app/models/attendance_payroll/ in M7)",
      "app/models/biometric_punch_log.rb"                      => "the model itself (moves to app/models/attendance_payroll/ in M7)",
      "app/models/attendance_record.rb"                        => "AP internal: has_many :biometric_punch_logs (punches that built the record)",
      "app/controllers/admin/biometric_devices_controller.rb"  => "AP device administration (BiometricDevicePolicy, manage_devices)",
      "app/controllers/admin/biometric_punch_logs_controller.rb" => "AP punch-log screens (visibility: SEC-M2-8, deferred)",
      "app/controllers/api/v1/biometric_base_controller.rb"    => "AP device-token realm: authenticates BiometricDevice",
      "app/controllers/api/v1/punches_controller.rb"           => "AP device punch endpoint: TimestampParser + PunchService",
      "app/controllers/api/v1/attendance_controller.rb"        => "AP mobile attendance: writes the mobile rejected_not_allowed punch log"
    }.freeze

    ATTENDANCE_PAYROLL_DIRS = [
      "app/views/admin/biometric_devices/",                    # AP device administration screens
      "app/views/admin/biometric_punch_logs/",                 # AP punch-log screens
      "app/services/attendance/"                               # PunchService, TimestampParser, AnomalyDetector (reads punch logs)
    ].freeze

    # Cross-domain exceptions, each documented in next-pilot-selection.md (Milestone 2 §14).
    EXCEPTION_FILES = {
      "app/models/business.rb"            => "Organization & Access inverse associations: has_many :biometric_devices / :biometric_punch_logs (same treatment as D-WF6)",
      "app/views/layouts/_sidebar.html.erb" => "UI shell: biometric devices nav entry (admin path and label key)",
      "app/helpers/workspace_helper.rb"   => "UI shell: Attendance workspace navigation (punch logs controller name)"
    }.freeze

    def allowed_files = ATTENDANCE_PAYROLL_FILES.merge(EXCEPTION_FILES)

    def source_files
      Dir.glob(Rails.root.join("{app,lib}/**/*.{rb,erb,rake}")).map { |f| f.delete_prefix("#{Rails.root}/") }.sort
    end

    # Full-line Ruby comments and ERB comments (including multi-line) are ignored.
    def code_lines(path)
      source = File.read(Rails.root.join(path))
      source = source.gsub(/<%#.*?%>/m) { |c| "\n" * c.count("\n") } if path.end_with?(".erb")
      source.each_line.with_index(1).reject { |line, _| line.lstrip.start_with?("#") }
    end

    def violations_in(path)
      code_lines(path).filter_map { |line, number| "#{path}:#{number}: #{line.strip}" if line.match?(FORBIDDEN) }
    end

    def allowed?(path)
      allowed_files.key?(path) || ATTENDANCE_PAYROLL_DIRS.any? { |dir| path.start_with?(dir) }
    end
  end
end

RSpec.describe "Architecture: Attendance & Payroll biometric boundary" do
  boundary = ArchitectureSpecs::AttendancePayrollBiometricBoundary

  it "has no direct BiometricDevice / BiometricPunchLog / PunchService / TimestampParser access outside Attendance & Payroll and the documented exceptions" do
    violations = boundary.source_files.reject { |path| boundary.allowed?(path) }.flat_map { |path| boundary.violations_in(path) }
    expect(violations).to be_empty, <<~MSG
      Direct access to Attendance & Payroll biometric internals from outside the domain:
      #{violations.join("\n")}
      Go through Attendance & Payroll code, or document a new exception in
      next-pilot-selection.md (Milestone 2 §14) and the allow-list.
    MSG
  end

  it "keeps the allow-list tight (every listed file still needs its entry)" do
    stale = boundary.allowed_files.keys.select { |path| !File.exist?(Rails.root.join(path)) || boundary.violations_in(path).empty? }
    expect(stale).to be_empty, "Remove from the allow-list: #{stale.join(', ')}"
  end

  it "keeps every allowed directory in use" do
    unused = boundary::ATTENDANCE_PAYROLL_DIRS.reject do |dir|
      boundary.source_files.any? { |path| path.start_with?(dir) && boundary.violations_in(path).any? }
    end
    expect(unused).to be_empty, "Remove from the allowed directories: #{unused.join(', ')}"
  end

  it "detects biometric internals and leaves policies, routes, flags and source strings alone" do
    expect("BiometricDevice.active.find_by(token: token)").to match(boundary::FORBIDDEN)
    expect("BiometricPunchLog.where(employee: user)").to match(boundary::FORBIDDEN)
    expect("current_user.business.biometric_devices.find(id)").to match(boundary::FORBIDDEN)
    expect("business.biometric_punch_logs.recent").to match(boundary::FORBIDDEN)
    expect("Attendance::PunchService.call(employee: e)").to match(boundary::FORBIDDEN)
    expect("Attendance::TimestampParser.parse(value)").to match(boundary::FORBIDDEN)
    expect("authorize BiometricDevicePolicy").not_to match(boundary::FORBIDDEN)
    expect("admin_biometric_devices_path; admin_biometric_punch_log_path(log)").not_to match(boundary::FORBIDDEN)
    expect("user.allow_biometric_attendance?").not_to match(boundary::FORBIDDEN)
    expect('check_in_source: "biometric_device"').not_to match(boundary::FORBIDDEN)
    expect("includes(:biometric_device)").not_to match(boundary::FORBIDDEN)
  end
end
