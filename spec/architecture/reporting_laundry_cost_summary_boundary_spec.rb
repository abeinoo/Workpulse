require "rails_helper"

# Boundary for Pilot 11 — Reporting: laundry labour-cost report (M6; see
# docs/architecture/next-pilot-selection.md §26).
#
# M4 moved Laundry::LaundryCostSummaryReport to the Reporting service location
# as Finance::Reports::LaundryCostSummary (D-P11-1, D-P11-2). Reporting reads
# every domain and owns or writes nothing (module-boundaries.md §9, §18 rule 9),
# and Pilot 11 introduced no read interfaces (D-P11-4). This spec keeps it so:
#
#   * the component (service, its Reporting UI controller and view — D-P11-3)
#     writes nothing;
#   * its reads are exactly the reasoned allow-list below (a new cross-domain
#     dependency, or a stale entry, fails);
#   * only its controller calls it — no other domain, Laundry (Inventory &
#     Purchasing) included, depends on Reporting;
#   * the pre-M4 name and file stay gone.
#
# The Finance & Sales boundary (finance_sales_expense_boundary_spec.rb) also
# lists the service among its read-only Reporting files for expenses.
module ArchitectureSpecs
  module ReportingLaundryCostSummaryBoundary
    module_function

    SERVICE    = "app/services/finance/reports/laundry_cost_summary.rb".freeze
    CONTROLLER = "app/controllers/laundry/reports/cost_summary_controller.rb".freeze
    VIEW       = "app/views/laundry/reports/cost_summary/index.html.erb".freeze
    COMPONENT_FILES = [ SERVICE, CONTROLLER, VIEW ].freeze

    # What the service reads from other domains, directly (D-P11-4). Each entry
    # must still be used; anything else fails.
    CROSS_DOMAIN_READS = {
      "Laundry::BranchTowelConsumptionReport" => "Inventory & Purchasing: towels received x standard rate (also read by Finance::Reports::ExpenseSources)",
      "StockIssue"                            => "Inventory & Purchasing: issued, non-voided stock issues to the laundry branch",
      "ShiftAssignment"                       => "Workforce: who worked at the laundry branch during a payroll period",
      "PayrollPeriod"                         => "Attendance & Payroll: finalized / paid periods overlapping the range",
      "PayrollEntry"                          => "Attendance & Payroll: net salary of those employees",
      "ExpenseAllocation"                     => "Finance & Sales: shared expenses allocated to the laundry branch"
    }.freeze

    # Reads through the acting business's associations (Organization & Access
    # branches; Finance & Sales expenses).
    BUSINESS_ASSOCIATION_READS = {
      "branches" => "Organization & Access: the single active laundry branch",
      "expenses" => "Finance & Sales: approved expenses in the period"
    }.freeze

    # The service's own names and Ruby core.
    OWN_CONSTANTS = %w[Finance Reports LaundryCostSummary Result MaterialLine Struct].freeze

    REMOVED_FILE     = "app/services/laundry/laundry_cost_summary_report.rb".freeze
    REMOVED_CONSTANT = "Laundry::LaundryCostSummaryReport".freeze

    COMPONENT_NAME = /\bLaundryCostSummary\b/
    REMOVED_NAME   = /\bLaundryCostSummaryReport\b/

    WRITE_CALL = /\.(?:create|update|update_all|update_columns?|update_attribute|save|destroy|destroy_all|delete|delete_all|
                    insert|insert_all|upsert|upsert_all|build|find_or_create_by|create_or_find_by|increment|decrement|toggle|
                    touch|lock|with_lock|perform_later|perform_now|deliver_later|deliver_now)!?(?=[(\s]|$)
                  | \blog_audit\b | \btransaction\b/x

    # Full-line comments and ERB comments are ignored; string contents are blanked
    # so a constant-looking word inside a string is not a dependency.
    def code_lines(path)
      source = File.read(Rails.root.join(path))
      source = source.gsub(/<%#.*?%>/m) { |c| "\n" * c.count("\n") } if path.end_with?(".erb")
      source.each_line.with_index(1).reject { |line, _| line.lstrip.start_with?("#") }
    end

    def matches_in(path, pattern)
      code_lines(path).filter_map { |line, number| "#{path}:#{number}: #{line.strip}" if line.match?(pattern) }
    end

    def constants_in(path)
      code_lines(path).flat_map { |line, _| line.gsub(/"[^"]*"|'[^']*'/, '""').scan(/(?<![\w:])[A-Z]\w*(?:::[A-Z]\w*)*/) }.uniq
    end

    def business_associations_in(path)
      code_lines(path).flat_map { |line, _| line.scan(/@business\.(\w+)/).flatten }.uniq
    end

    def source_files(root = "{app,lib}")
      Dir.glob(Rails.root.join("#{root}/**/*.{rb,erb,rake}")).map { |f| f.delete_prefix("#{Rails.root}/") }.sort
    end
  end
end

RSpec.describe "Architecture: Reporting laundry cost summary boundary" do
  boundary = ArchitectureSpecs::ReportingLaundryCostSummaryBoundary

  it "the component (service, controller, view) writes nothing" do
    writes = boundary::COMPONENT_FILES.flat_map { |path| boundary.matches_in(path, boundary::WRITE_CALL) }
    expect(writes).to be_empty, "Reporting must not write:\n#{writes.join("\n")}"
  end

  it "the service reads exactly the reasoned cross-domain allow-list (no new dependency, no stale entry)" do
    constants = boundary.constants_in(boundary::SERVICE) - boundary::OWN_CONSTANTS
    expect(constants).to match_array(boundary::CROSS_DOMAIN_READS.keys)

    expect(boundary.business_associations_in(boundary::SERVICE)).to match_array(boundary::BUSINESS_ASSOCIATION_READS.keys)
  end

  it "only its controller calls it (no other domain depends on Reporting)" do
    files  = boundary.source_files + boundary.source_files("config")
    namers = files.select { |path| boundary.matches_in(path, boundary::COMPONENT_NAME).any? }
    expect(namers).to contain_exactly(boundary::SERVICE, boundary::CONTROLLER)
    expect(boundary.matches_in(boundary::CONTROLLER, /\bFinance::Reports::LaundryCostSummary\.new\b/).size).to eq(1)
  end

  it "the pre-M4 file and constant stay gone, and no code names them" do
    expect(File.exist?(Rails.root.join(boundary::REMOVED_FILE))).to be(false)
    expect(Object.const_defined?(boundary::REMOVED_CONSTANT)).to be(false)

    named = (boundary.source_files + boundary.source_files("config")).flat_map { |path| boundary.matches_in(path, boundary::REMOVED_NAME) }
    expect(named).to be_empty, named.join("\n")
  end

  it "the relocated service is the constant Zeitwerk expects in the Reporting location" do
    expect(Rails.autoloaders.main.cpath_expected_at(Rails.root.join(boundary::SERVICE))).to eq("Finance::Reports::LaundryCostSummary")
  end

  describe "self-tests (planted probes)" do
    def plant(path, content)
      unless @reads_stubbed
        allow(File).to receive(:read).and_call_original
        @reads_stubbed = true
      end
      allow(File).to receive(:read).with(Rails.root.join(path)).and_return(content)
    end

    it "catches writes planted in the service, the controller and the view" do
      plant(boundary::SERVICE, "PayrollEntry.where(id: 1).update_all(net_salary: 0)\nlaundry_branch.touch\n" \
                               "Expense.create!(amount: 1)\nlog_audit(actor: a, auditable: b, action: \"x\")\n")
      plant(boundary::CONTROLLER, "current_user.business.update!(name: \"x\")\nRecalcJob.perform_later(1)\n")
      plant(boundary::VIEW, "<% @summary.laundry_branch.save %>\n")
      writes = boundary::COMPONENT_FILES.flat_map { |path| boundary.matches_in(path, boundary::WRITE_CALL) }
      expect(writes.size).to eq(7)
    end

    it "catches a new cross-domain dependency and a stale allow-list entry" do
      plant(boundary::SERVICE, File.read(Rails.root.join(boundary::SERVICE)) + "Payroll::EntryRecalculator.call(user: u)\n")
      expect(boundary.constants_in(boundary::SERVICE) - boundary::OWN_CONSTANTS - boundary::CROSS_DOMAIN_READS.keys)
        .to eq([ "Payroll::EntryRecalculator" ])

      plant(boundary::SERVICE, "class LaundryCostSummary\n  StockIssue.for_business(@business)\nend\n")
      expect(boundary::CROSS_DOMAIN_READS.keys - boundary.constants_in(boundary::SERVICE)).not_to be_empty
    end

    it "catches a new business association read" do
      plant(boundary::SERVICE, "@business.branches\n@business.payroll_periods.where(status: \"paid\")\n")
      expect(boundary.business_associations_in(boundary::SERVICE) - boundary::BUSINESS_ASSOCIATION_READS.keys)
        .to eq([ "payroll_periods" ])
    end

    it "catches another domain (Laundry included) calling the component, bare or namespaced" do
      plant("app/services/laundry/towel_balances.rb", "Finance::Reports::LaundryCostSummary.new(b, from: f, to: t).call\n")
      plant("app/services/payroll/approver.rb", "LaundryCostSummary.new(b, from: f, to: t)\n")
      expect(boundary.matches_in("app/services/laundry/towel_balances.rb", boundary::COMPONENT_NAME)).not_to be_empty
      expect(boundary.matches_in("app/services/payroll/approver.rb", boundary::COMPONENT_NAME)).not_to be_empty
    end

    it "catches the pre-M4 name planted back" do
      plant(boundary::CONTROLLER, "@summary = Laundry::LaundryCostSummaryReport.new(b, from: f, to: t).call\n")
      expect(boundary.matches_in(boundary::CONTROLLER, boundary::REMOVED_NAME).size).to eq(1)
    end

    it "does not flag comments, ERB comments or constant-looking words inside strings" do
      plant(boundary::SERVICE, "# See Laundry::LaundryCostSummaryReport and Payroll::EntryRecalculator.call(save!)\n" \
                               "x = \"Payroll::EntryRecalculator\"\n")
      plant(boundary::VIEW, "<%# @summary.laundry_branch.save %>\n")
      expect(boundary.constants_in(boundary::SERVICE)).to be_empty
      expect(boundary.matches_in(boundary::SERVICE, boundary::REMOVED_NAME)).to be_empty
      expect(boundary.matches_in(boundary::VIEW, boundary::WRITE_CALL)).to be_empty
    end
  end
end
