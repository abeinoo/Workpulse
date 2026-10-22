require "rails_helper"
require Rails.root.join("script/architecture/dependency_inventory").to_s

# The repository-wide domain dependency inventory — ENFORCED (decision D3,
# module-boundaries.md §19 step 0 and §20.3; next-pilot-selection.md §45). It
# was report-only from 9468678 until its coverage and reliability were shown.
#
# Gate: every app/ file and every schema table is mapped to a domain; every
# cross-domain reference is allowed (§12.1 direction) or a D4 exception of
# docs/architecture/dependency-exceptions.md; no exception is stale. The rest of
# the file proves the tool: mapping, resolution, the three detection kinds,
# classification, determinism (independent of autoload order) and planted
# violations. What it cannot see is stated in the report header and left to the
# per-component boundary specs.
RSpec.describe "Architecture: domain dependency inventory (enforced)" do
  inventory = ArchitectureTools::DependencyInventory
  result = nil

  before(:context) { result = inventory.inventory }

  describe "the gate" do
    it "has no unclassified cross-domain reference" do
      violations = inventory.violations(result)
      expect(violations).to be_empty, <<~MSG
        Unclassified cross-domain references (route them through the owner's interface, or classify them as a D4
        exception in script/architecture/dependency_inventory.rb CLASSIFIED and docs/architecture/dependency-exceptions.md):
        #{violations.map { "#{_1.source} → #{_1.target}  #{_1.path}:#{_1.line}  #{_1.constant} (#{_1.kind})" }.uniq.join("\n")}
      MSG
    end

    it "maps every app/ file" do
      expect(result[:unmapped]).to be_empty, "Map in FILE_RULES / MODEL_OWNERS: #{result[:unmapped].join(', ')}"
    end

    it "maps every table of db/schema.rb, and every model's table is the one Rails uses" do
      unmapped = inventory.schema_tables.reject { inventory.table_owner(_1) }
      expect(unmapped).to be_empty, "Map in MODEL_OWNERS / NON_MODEL_TABLES: #{unmapped.join(', ')}"
      mismatched = inventory::MODEL_OWNERS.keys.reject { _1 == "ApplicationRecord" }.reject do |model|
        klass = model.safe_constantize
        klass.nil? || !(klass < ActiveRecord::Base) || inventory::TABLE_OWNERS.dig(klass.table_name, :model) == model
      end
      expect(mismatched).to be_empty
    end

    it "lists every exception in the D4 register, with the same IDs, and none is stale" do
      register = File.read(Rails.root.join("docs/architecture/dependency-exceptions.md"))
      section  = register[/## Checker exceptions\n(.*?)\n## /m, 1]
      listed   = section.scan(/^\| (X-[A-Z0-9-]+) \|/).flatten
      expect(listed).to match_array(inventory::CLASSIFIED.map(&:id))
      expect(inventory.unused_exceptions(result)).to be_empty
      inventory::CLASSIFIED.each do |exception|
        expect(exception.to_h.values_at(:owner, :reason, :guard)).to all(be_present), exception.id
      end
    end
  end

  describe "file and table mapping" do
    it "maps representative files of every layer" do
      {
        "app/models/user.rb" => :organization_access, "app/lib/phone_number.rb" => :organization_access,
        "app/services/organization_access/accounts.rb" => :organization_access,
        "app/models/shift_assignment.rb" => :workforce, "app/controllers/admin/users_controller.rb" => :workforce,
        "app/policies/user_policy.rb" => :workforce, "app/services/employee/performance_scorer.rb" => :attendance_payroll,
        "app/views/shared/_adjustment_already_paid_section.html.erb" => :attendance_payroll,
        "app/models/purchase_request_advance.rb" => :inventory_purchasing,
        "app/services/finance/reports/expense_summary.rb" => :finance_sales,
        "app/services/finance/reports/branch_profitability.rb" => :reporting,
        "app/controllers/laundry/reports/cost_summary_controller.rb" => :reporting,
        "app/lib/business_day.rb" => :shared_kernel, "app/helpers/workspace_helper.rb" => :infrastructure,
        "app/javascript/controllers/index.js" => :frontend
      }.each { |path, domain| expect(inventory.domain_of_file(path)).to eq(domain), path }
    end

    it "reports an unmapped file instead of ignoring it" do
      partial = inventory.inventory([ "app/models/user.rb", "app/widgets/new_thing.rb" ])
      expect(partial[:unmapped]).to eq([ "app/widgets/new_thing.rb" ])
    end

    it "maps legacy and infrastructure tables" do
      expect(inventory.table_owner("product_variants")).to eq(owner: :inventory_purchasing, model: nil)
      expect(inventory.table_owner("solid_queue_jobs")[:owner]).to eq(:infrastructure)
      expect(inventory.table_owner("attendance_records")).to eq(owner: :attendance_payroll, model: "AttendanceRecord")
      expect(inventory.table_owner("no_such_table")).to be_nil
    end
  end

  describe "constant resolution" do
    it "resolves models, policies, nested constants and namespaces, longest prefix first; ignores Ruby / Rails" do
      {
        "PayrollEntry" => :attendance_payroll, "CustodyAccountPolicy::Scope" => :finance_sales,
        "PenaltyRule::RULE_TYPES" => :attendance_payroll, "Finance::Reports::Column" => :finance_sales,
        "Finance::Reports::ExpenseSources" => :reporting, "Employee::PerformanceScorer" => :attendance_payroll,
        "Employee::ProfilePanels" => :workforce, "::User" => :organization_access, "PhoneNumber" => :organization_access,
        "BusinessDay" => :shared_kernel, "ApplicationPolicy" => :infrastructure,
        "Date" => nil, "ActiveRecord::Base" => nil, "Pundit::NotAuthorizedError" => nil
      }.each { |constant, domain| expect(inventory.owner_of(constant)).to eq(domain), constant }
    end

    it "resolves an unqualified constant against its file's namespace only when it exists there" do
      path = "app/services/finance/reports/branch_profitability.rb"
      expect(inventory.resolve("ExpenseSources", path)).to eq("Finance::Reports::ExpenseSources")
      expect(inventory.resolve("Date", path)).to eq("Date")
    end
  end

  describe "detection (planted references)" do
    def refs(path, code) = ArchitectureTools::DependencyInventory.references_in(path, code)

    it "a constant: an Inventory service writing the custody ledger is a violation" do
      expect(refs("app/services/inventory/goods_receipt_voider.rb", "CustodyTransaction.create!(amount: 1)\n")
               .map { [ _1.source, _1.target, _1.constant, _1.kind, _1.status ] })
        .to eq([ [ :inventory_purchasing, :finance_sales, "CustodyTransaction", :constant, :unclassified ] ])
    end

    it "an association: an Organization & Access service model associating a payroll record is a violation" do
      planted = refs("app/models/user_audit_log.rb", "  has_many :payroll_entries\n  belongs_to :approver, class_name: \"Advance\"\n")
      expect(planted.map { [ _1.constant, _1.kind, _1.status ] })
        .to eq([ [ "PayrollEntry", :association, :unclassified ], [ "Advance", :association, :unclassified ] ])
    end

    it "raw SQL: a Workforce controller reading attendance_records in a string is a violation" do
      planted = refs("app/controllers/shift_assignments_controller.rb",
                     "Arel.sql(\"EXISTS(SELECT 1 FROM attendance_records ar WHERE ar.id = 1)\")\n")
      expect(planted.map { [ _1.constant, _1.kind, _1.status ] }).to eq([ [ "AttendanceRecord", :sql, :unclassified ] ])
    end

    it "a polymorphic type string: an Organization & Access service naming a payroll model is a violation" do
      planted = refs("app/services/organization_access/x.rb", "PayrollLineItem.where(source_type: \"Advance\")\n")
      expect(planted.map { [ _1.constant, _1.kind, _1.status ] })
        .to eq([ [ "PayrollLineItem", :constant, :unclassified ], [ "Advance", :polymorphic_type, :unclassified ] ])
      expect(refs("app/services/payroll/x.rb", "x.where(source_type: \"Advance\", label_type: \"Weekly\")\n")).to be_empty
    end

    it "an exception covers only its own scope" do
      classified = refs("app/views/admin/shifts/_form.html.erb", "<%= select_tag :x, PenaltyRule::RULE_TYPES %>\n")
      expect(classified.map { [ _1.status, _1.exception.id ] }).to eq([ [ :classified, "X-WF-PENALTY-OPTIONS" ] ])
      expect(refs("app/views/admin/shifts/index.html.erb", "<%= PayrollEntry.count %>\n").map(&:status)).to eq([ :unclassified ])
      expect(refs("app/controllers/admin/branches_controller.rb", "Advance.count\n").map(&:status)).to eq([ :unclassified ])
    end

    it "allows the §12.1 directions and never reports same-domain or shared references" do
      expect(refs("app/services/payroll/x.rb", "ShiftAssignment.current\nUser.find(1)\n").map(&:status)).to eq(%i[allowed allowed])
      expect(refs("app/services/payroll/x.rb", "PayrollEntry.first\nBusinessDay.current(context: b)\n")).to be_empty
      expect(refs("app/services/dashboard/owner_data.rb", "Expense.count\n  has_many :payroll_entries\n").map(&:status))
        .to eq(%i[allowed allowed])
    end

    it "ignores comments, i18n keys, ERB text, polymorphic associations and non-SQL strings" do
      code = "# PayrollEntry\nt(\"payroll_entries.title\")\nx = 'select CustodyAccount'\n  belongs_to :source, polymorphic: true\n" \
             "label = \"Payroll from attendance_records\"\n"
      expect(refs("app/services/organization_access/x.rb", code)).to be_empty
      erb = "<p>PayrollEntry here</p>\n<%# PayrollEntry %>\n<%= t(\"PayrollEntry\") %>\n"
      expect(refs("app/views/admin/branches/show.html.erb", erb)).to be_empty
    end

    it "fails the gate when a planted violation is added to the inventory" do
      planted = inventory.references_in("app/services/organization_access/permission_grants.rb", "PayrollEntry.where(user: u)\n")
      expect(inventory.violations(result.merge(references: result[:references] + planted))).to eq(planted)
    end
  end

  describe "determinism" do
    it "gives the same report before and after eager loading the application" do
      before_load = inventory.report(result)
      Rails.application.eager_load!
      expect(inventory.report(inventory.inventory)).to eq(before_load)
      expect(before_load).not_to match(/\d{4}-\d{2}-\d{2}T/)
    end
  end
end
