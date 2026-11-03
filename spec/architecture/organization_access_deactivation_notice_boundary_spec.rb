require "rails_helper"

# Boundary for BUG-029 — the Organization & Access branch page shows what Laundry
# and Attendance & Payroll still record at a branch only through the contract
# OrganizationAccess::BranchDeactivationNotices (module-boundaries.md §12.1);
# X-OA-BRANCH-PAGE is deliberately NOT widened to either domain.
#
# Why Organization & Access may show these notices without depending on the
# providers: OA defines the contract and the Notice / Line data it renders;
# Laundry and Attendance & Payroll — both downstream of OA (LA → OA and AP → OA
# are allowed edges) — implement it, and only the composition root names the
# implementations. OA code holds the provider list as opaque objects that answer
# notices_for; it never names a provider, a device, a towel or their tables.
#
# Rules:
# 1. The branch page's controller and views name no Laundry or Attendance &
#    Payroll provider constant or table.
# 2. The page asks for the notices exactly once, in the controller, and the
#    dialog renders only what it is given.
# 3. The contract names nothing from Laundry or Attendance & Payroll; each
#    implementation is named only by itself and the composition root, which
#    registers them together, in order, as the providers.
module ArchitectureSpecs
  module OrganizationAccessDeactivationNoticeBoundary
    module_function

    PAGE_FILES = %w[app/controllers/admin/branches_controller.rb] +
                 Dir.glob("app/views/admin/branches/**/*.erb", base: Rails.root.to_s).sort
    CONTRACT_FILE    = "app/services/organization_access/branch_deactivation_notices.rb".freeze
    IMPLEMENTATIONS  = {
      "Laundry::BranchDeactivationNotice"    => "app/services/laundry/branch_deactivation_notice.rb",
      "Attendance::BranchDeactivationNotice" => "app/services/attendance/branch_deactivation_notice.rb"
    }.freeze
    COMPOSITION_ROOT = "config/initializers/branch_deactivation_notices.rb".freeze

    LAUNDRY = /\bLaundry::|\b(Towel(Type|LedgerEntry|Transfer|TransferItem|Adjustment)|LaundryBatch)\b|\b(towel_\w+|laundry_batch\w*)\b(?!_path|_url)/
    # The Attendance & Payroll provider and the device data it reads.
    ATTENDANCE = /\bAttendance::BranchDeactivationNotice\b|\bBiometric(Device|PunchLog)\b|\bbiometric_(devices|punch_logs)\b(?!_path|_url)/

    def code_lines(path)
      source = File.read(Rails.root.join(path))
      source = source.gsub(/<%#.*?%>/m) { |c| "\n" * c.count("\n") } if path.end_with?(".erb")
      source.each_line.with_index(1).reject { |line, _| line.lstrip.start_with?("#") }
            .map { |line, number| [ line.gsub(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/, '""').sub(/\s#\s.*$/, ""), number ] }
    end

    def matches_in(path, pattern) = code_lines(path).filter_map { |l, n| "#{path}:#{n}: #{l.strip}" if l.match?(pattern) }

    def source_files(root = "{app,lib}")
      Dir.glob(Rails.root.join("#{root}/**/*.{rb,erb,rake}")).map { _1.delete_prefix("#{Rails.root}/") }.sort
    end
  end
end

RSpec.describe "Architecture: the OA branch page gets Laundry's deactivation notice only through OrganizationAccess::BranchDeactivationNotices (BUG-029)" do
  boundary = ArchitectureSpecs::OrganizationAccessDeactivationNoticeBoundary

  it "the branch page names no Laundry or Attendance & Payroll constant or table (rule 1)" do
    found = boundary::PAGE_FILES.flat_map { boundary.matches_in(_1, boundary::LAUNDRY) + boundary.matches_in(_1, boundary::ATTENDANCE) }
    expect(found).to be_empty, "Use OrganizationAccess::BranchDeactivationNotices:\n#{found.join("\n")}"
  end

  it "the controller asks once and the dialog renders only what it is given (rule 2)" do
    calls = boundary::PAGE_FILES.flat_map { boundary.matches_in(_1, /BranchDeactivationNotices\.\w+/) }
    expect(calls.map { _1.split(":").first }).to eq([ "app/controllers/admin/branches_controller.rb" ])
    expect(calls.first).to match(/BranchDeactivationNotices\.notices_for\(branch: @branch\)/)
    expect(boundary.matches_in("app/views/admin/branches/show.html.erb", /@deactivation_notices/).size).to eq(1)
  end

  it "the contract, implementations and composition root are where they belong (rule 3)" do
    expect(boundary.matches_in(boundary::CONTRACT_FILE, boundary::LAUNDRY)).to be_empty
    expect(boundary.matches_in(boundary::CONTRACT_FILE, boundary::ATTENDANCE)).to be_empty

    boundary::IMPLEMENTATIONS.each do |constant, file|
      outside = (boundary.source_files + boundary.source_files("config"))
                .reject { [ file, boundary::COMPOSITION_ROOT ].include?(_1) }
                .flat_map { boundary.matches_in(_1, /\b#{Regexp.escape(constant)}\b/) }
      expect(outside).to be_empty, "#{constant} is named outside its file and the composition root:\n#{outside.join("\n")}"
    end

    root = File.read(Rails.root.join(boundary::COMPOSITION_ROOT))
    expect(root.scan(/BranchDeactivationNotices\.register\(/).size).to eq(1)
    expect(root).to match(/register\(\s*Laundry::BranchDeactivationNotice,\s*Attendance::BranchDeactivationNotice\s*\)/)
    expect(OrganizationAccess::BranchDeactivationNotices.providers)
      .to eq([ Laundry::BranchDeactivationNotice, Attendance::BranchDeactivationNotice ])
  end

  describe "self-tests" do
    it "catches Laundry reads planted on the page, and ignores route helpers, i18n keys and comments" do
      [ "Laundry::TowelBalances.totals_for(business)", "TowelTransfer.dispatched.count",
        "LaundryBatch.in_progress", "@branch.towel_ledger_entries.sum(:quantity)" ].each do |code|
        expect(code).to match(boundary::LAUNDRY), code
      end
      [ "laundry_towel_transfers_path", "t(\"laundry.deactivation_notice.title\")", "# TowelTransfer in a comment" ].each do |code|
        line = code.gsub(/"(?:[^"\\]|\\.)*"/, '""').sub(/\A#.*/, "")
        expect(line).not_to match(boundary::LAUNDRY), code
      end
    end

    it "catches Attendance & Payroll reads planted on the page, and ignores route helpers and i18n keys" do
      [ "Attendance::BranchDeactivationNotice.notices_for(branch: @branch)", "BiometricDevice.where(branch_id: @branch.id)",
        "@branch.business.biometric_devices.count", "BiometricPunchLog.where(branch: @branch)" ].each do |code|
        expect(code).to match(boundary::ATTENDANCE), code
      end
      [ "admin_biometric_devices_path", "t(\"attendance.deactivation_notice.title\")" ].each do |code|
        line = code.gsub(/"(?:[^"\\]|\\.)*"/, '""')
        expect(line).not_to match(boundary::ATTENDANCE), code
      end
    end
  end
end
