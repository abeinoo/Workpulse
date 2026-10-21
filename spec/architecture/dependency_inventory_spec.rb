require "rails_helper"
require Rails.root.join("script/architecture/dependency_inventory").to_s

# The repository-wide domain dependency inventory (module-boundaries.md §19 step 0)
# in REPORT-ONLY mode: these examples prove the tool — file mapping, constant
# resolution, direction rules, classification, determinism and planted-reference
# detection — but never assert that the application has no unclassified
# reference. The current findings live in docs/architecture/dependency-inventory-report.txt
# (`bin/rails architecture:dependency_report`). Enforcement is a separate,
# documented decision (next-pilot-selection.md §40).
RSpec.describe "Architecture: domain dependency inventory (report-only)" do
  inventory = ArchitectureTools::DependencyInventory

  describe "file mapping" do
    it "maps representative files of every layer" do
      {
        "app/models/user.rb"                                         => :organization_access,
        "app/models/organization_access/permission_role.rb"          => :organization_access,
        "app/services/employee_scope.rb"                             => :organization_access,
        "app/models/shift_assignment.rb"                             => :workforce,
        "app/controllers/admin/users_controller.rb"                  => :workforce,
        "app/policies/user_policy.rb"                                => :workforce,
        "app/services/employee/insurance_profile_updater.rb"         => :workforce,
        "app/services/employee/performance_scorer.rb"                => :attendance_payroll,
        "app/models/attendance_payroll/penalty_rule.rb"              => :attendance_payroll,
        "app/views/shared/_adjustment_already_paid_section.html.erb" => :attendance_payroll,
        "app/models/purchase_request_advance.rb"                     => :inventory_purchasing,
        "app/controllers/laundry/reports/branch_consumption_controller.rb" => :inventory_purchasing,
        "app/models/finance_sales/expense.rb"                        => :finance_sales,
        "app/services/finance/reports/expense_summary.rb"            => :finance_sales,
        "app/controllers/finance/reports_controller.rb"              => :finance_sales,
        "app/services/finance/reports/branch_profitability.rb"       => :reporting,
        "app/controllers/laundry/reports/cost_summary_controller.rb" => :reporting,
        "app/policies/operations_dashboard_policy.rb"                => :reporting,
        "app/lib/business_day.rb"                                    => :shared_kernel,
        "app/helpers/workspace_helper.rb"                            => :infrastructure,
        "app/javascript/controllers/index.js"                        => :frontend
      }.each { |path, domain| expect(inventory.domain_of_file(path)).to eq(domain), path }
    end

    it "reports a file no rule maps as unmapped instead of ignoring it" do
      result = inventory.inventory([ "app/models/user.rb", "app/widgets/new_thing.rb" ])
      expect(result[:unmapped]).to eq([ "app/widgets/new_thing.rb" ])
      expect(inventory.report(result)).to include("[unmapped]\napp/widgets/new_thing.rb")
    end

    it "covers every file under app/ in the report (mapped or listed as unmapped)" do
      result = inventory.inventory
      expect(result[:files].size).to eq(Dir.glob(Rails.root.join("app/**/*")).count { File.file?(_1) })
      expect(result[:mapped].values.sum(&:size) + result[:unmapped].size).to eq(result[:files].size)
    end
  end

  describe "constant resolution" do
    it "resolves models, policies, nested constants and namespaces, longest prefix first" do
      {
        "PayrollEntry" => :attendance_payroll, "CustodyAccountPolicy::Scope" => :finance_sales,
        "PenaltyRule::RULE_TYPES" => :attendance_payroll, "Finance::Reports::Column" => :finance_sales,
        "Finance::Reports::ExpenseSources" => :reporting, "Finance::Dashboard::KpiBuilder" => :reporting,
        "Employee::InsuranceProfileEffects" => :workforce, "Employee::PerformanceScorer" => :attendance_payroll,
        "Inventory::GoodsReceiptPaymentEffects" => :inventory_purchasing, "::User" => :organization_access,
        "BusinessDay" => :shared_kernel, "ApplicationPolicy" => :infrastructure
      }.each { |constant, domain| expect(inventory.owner_of(constant)).to eq(domain), constant }
    end

    it "ignores Ruby, Rails and gem constants" do
      %w[Date Time ActiveRecord::Base Rails I18n Struct BigDecimal Pundit::NotAuthorizedError].each do |constant|
        expect(inventory.owner_of(constant)).to be_nil, constant
      end
    end

    it "resolves an unqualified constant against its file's namespace only when it exists there" do
      path = "app/services/finance/reports/branch_profitability.rb"
      expect(inventory.resolve("ExpenseSources", path)).to eq("Finance::Reports::ExpenseSources")
      expect(inventory.resolve("Date", path)).to eq("Date")
    end
  end

  describe "classification" do
    def refs(path, code) = ArchitectureTools::DependencyInventory.references_in(path, code)

    it "allows the §12.1 directions and never reports same-domain or shared references" do
      expect(refs("app/services/payroll/x.rb", "ShiftAssignment.current\nUser.find(1)\n").map(&:status)).to eq(%i[allowed allowed])
      expect(refs("app/services/payroll/x.rb", "PayrollEntry.first\nBusinessDay.current(context: b)\n")).to be_empty
      expect(refs("app/services/dashboard/owner_data.rb", "Expense.count\nPayrollEntry.count\n").map(&:status))
        .to eq(%i[allowed allowed])
    end

    it "detects a planted upward write (Inventory → Finance & Sales) as unclassified" do
      planted = refs("app/services/inventory/goods_receipt_voider.rb", "CustodyTransaction.create!(amount: 1)\n")
      expect(planted.map { [ _1.source, _1.target, _1.constant, _1.status ] })
        .to eq([ [ :inventory_purchasing, :finance_sales, "CustodyTransaction", :unclassified ] ])
    end

    it "detects a planted Organization & Access → Attendance & Payroll read as unclassified" do
      planted = refs("app/services/organization_access/permission_grants.rb", "PayrollEntry.where(user: u)\n")
      expect(planted.map(&:status)).to eq([ :unclassified ])
    end

    it "classifies only the recorded exceptions, citing where each is recorded" do
      classified = refs("app/views/admin/shifts/_form.html.erb", "<%= select_tag :x, PenaltyRule::RULE_TYPES %>\n")
      expect(classified.map(&:status)).to eq([ :classified ])
      expect(classified.first.reason).to include("attendance_payroll_penalty_rule_boundary_spec.rb")

      other_view = refs("app/views/admin/shifts/index.html.erb", "<%= PayrollEntry.count %>\n")
      expect(other_view.map(&:status)).to eq([ :unclassified ])

      inventory::CLASSIFIED.each do |_, _, reason|
        expect(reason).to match(/_spec\.rb|§\d+/), "classification without a recorded source: #{reason}"
      end
    end

    it "ignores comments, strings, i18n keys and ERB text" do
      code = "# PayrollEntry in a comment\nt(\"payroll_entries.title\")\nx = 'CustodyAccount'\nclass_name: \"Advance\"\n"
      expect(refs("app/services/organization_access/x.rb", code)).to be_empty
      erb = "<p>PayrollEntry is shown here</p>\n<%# PayrollEntry %>\n<%= t(\"PayrollEntry\") %>\n"
      expect(refs("app/views/admin/branches/show.html.erb", erb)).to be_empty
    end
  end

  describe "report" do
    it "is deterministic and lists every status section" do
      result = inventory.inventory
      first  = inventory.report(result)
      expect(inventory.report(inventory.inventory)).to eq(first)
      expect(first).to include("[unmapped]", "[unclassified]", "[classified]", "[allowed]", "REPORT-ONLY")
      expect(first).not_to match(/\d{4}-\d{2}-\d{2}T/)
    end
  end
end
