require "rails_helper"

# Organization & Access outbound boundary (Batch W; module-boundaries.md §12.1,
# §12.2 "OA → FS/IP/AP", §14.2 #10; next-pilot-selection.md §28). Organization &
# Access is the top of the graph: it must not write downstream domains' data.
#
# Rules:
# 1. Warehouse access (Inventory & Purchasing: WarehouseAssignment, the
#    warehouse_assignments / assigned_warehouses associations, the ids writer)
#    is named only by Inventory & Purchasing code and the classified User lines;
#    the employee form reaches it only through the Organization & Access
#    contract OrganizationAccess::UserWarehouseAccess, implemented by Inventory
#    & Purchasing (Inventory::UserWarehouseAssignments) and wired in
#    config/initializers/user_warehouse_access.rb.
# 2. The inverse associations Business, Branch and User hold into other domains
#    are classified, per owning domain, and frozen: adding or removing one is an
#    architectural decision (they are lifecycle / read-traversal exceptions —
#    target: the owning domains, §12.2).
# 3. WorkspaceHelper is the UI shell's navigation registry (infrastructure): it
#    names other domains' models only as policy(Model) gates — never a query or
#    a write.
#
# Not guarded: the form's HTTP parameter name assigned_warehouse_ids, the
# account-tier entry in UserPolicy::ACCOUNT_ATTRIBUTES, route helpers, i18n keys.
module ArchitectureSpecs
  module OrganizationAccessOutboundBoundary
    module_function

    WAREHOUSE_ACCESS = /
      \bWarehouseAssignment\b
      | \bwarehouse_assignments\b
      | \bassigned_warehouses\b
      | \bUserWarehouseAssignments\b
      | assigned_warehouse_ids\s*=(?!=)
    /x

    INVENTORY_FILES = {
      "app/models/warehouse_assignment.rb"              => "IP: the model",
      "app/models/warehouse.rb"                         => "IP: Warehouse has_many :warehouse_assignments / :assigned_users",
      "app/services/inventory/user_warehouse_assignments.rb" => "IP implementation of OrganizationAccess::UserWarehouseAccess"
    }.freeze

    # The only lines app/models/user.rb may contain about warehouse access.
    USER_FILE  = "app/models/user.rb".freeze
    USER_LINES = [
      /\Ahas_many :warehouse_assignments, dependent: :destroy\z/,                              # lifecycle: rows die with the user
      /\Ahas_many :assigned_warehouses,\s+through: :warehouse_assignments, source: :warehouse\z/, # read traversal (form checkboxes)
      /\Aids = warehouse_assignments\.pluck\(:warehouse_id\)\z/                                 # User#inventory_warehouse_ids: the fail-open IP rule, unchanged
    ].freeze

    CONTRACT_FILE    = "app/services/organization_access/user_warehouse_access.rb".freeze
    CONTROLLER       = "app/controllers/admin/users_controller.rb".freeze
    COMPOSITION_ROOT = "config/initializers/user_warehouse_access.rb".freeze

    # Owning domain of every model an Organization & Access model associates
    # with (module-boundaries.md §10).
    DOMAIN_OF = {
      organization_access: %w[Branch User PermissionRole],
      workforce: %w[Shift ShiftAssignment EmployeeRequest Department JobTitle EvaluationTemplate PerformanceReview
                    PerformanceObservation EmployeeInsuranceProfile],
      attendance_payroll: %w[AttendanceRecord PayrollPeriod PayrollEntry SalaryProfile Advance EmployeeObligation
                             BiometricDevice BiometricPunchLog],
      inventory_purchasing: %w[Warehouse WarehouseAssignment WarehouseBranchSupply Supplier Brand ProductCategory Product
                               GoodsReceipt PurchaseRequest StockIssue StockIssueImportBatch StockTransfer StockAdjustment
                               StockCount InventoryMovement TowelType TowelLedgerEntry TowelTransfer TowelAdjustment
                               LaundryBatch LaundryStandardCostRate Service],
      finance_sales: %w[Expense ExpenseAllocation ExpenseCategory ExpenseType ExpenseTag RecurringExpense BalanceRequest
                        CustodyAccount CustodyTransaction BranchRevenue SalesImport PosImport PosTransaction PosTerminal
                        BankStatement]
    }.flat_map { |domain, models| models.map { |model| [ model, domain ] } }.to_h.freeze

    # Classified inverse associations into other domains (frozen). Business is
    # the tenancy root (dependent: rules, business-scoped traversal); Branch and
    # User associations are lifecycle (restrict / destroy) and read traversal.
    INVERSE_ASSOCIATIONS = {
      "Business" => {
        workforce: %i[shifts departments job_titles evaluation_templates performance_reviews performance_observations
                      employee_insurance_profiles],
        attendance_payroll: %i[employee_obligations payroll_periods biometric_devices biometric_punch_logs],
        inventory_purchasing: %i[warehouses suppliers brands product_categories products goods_receipts purchase_requests
                                 stock_issues stock_transfers stock_adjustments stock_counts inventory_movements
                                 stock_issue_import_batches towel_types towel_ledger_entries towel_transfers laundry_batches
                                 towel_adjustments services laundry_standard_cost_rates],
        finance_sales: %i[expense_categories expense_types expense_tags expenses balance_requests recurring_expenses
                          custody_accounts custody_transactions branch_revenues sales_imports pos_imports pos_terminals
                          bank_statements]
      },
      "Branch" => {
        workforce: %i[shift_assignments],
        attendance_payroll: %i[attendance_records payroll_periods],
        inventory_purchasing: %i[warehouse_supply towel_ledger_entries outgoing_towel_transfers incoming_towel_transfers
                                 laundry_batches],
        finance_sales: %i[expenses expense_allocations recurring_expenses custody_accounts branch_revenues pos_transactions
                          pos_terminals]
      },
      "User" => {
        workforce: %i[shift_assignments employee_requests employee_insurance_profile performance_reviews performance_observations],
        attendance_payroll: %i[salary_profiles active_salary_profile attendance_records advances payroll_entries employee_obligations],
        inventory_purchasing: %i[warehouse_assignments assigned_warehouses],
        finance_sales: %i[custody_accounts]
      }
    }.freeze

    WORKSPACE_HELPER   = "app/helpers/workspace_helper.rb".freeze
    WORKSPACE_OWN      = %w[WorkspaceHelper Workspace Section Struct].freeze
    # Workspace-level access gates the registry reads (permission-name lists the
    # domains' base controllers also check) — read-only, no model involved.
    WORKSPACE_GATES    = %w[Finance::BaseController::FINANCE_PERMISSIONS Laundry::BaseController::LAUNDRY_PERMISSIONS].freeze

    def workspace_offending_lines(lines)
      lines.filter_map do |line, number|
        stripped  = WORKSPACE_GATES.reduce(line.gsub(/policy\([A-Z][\w:]*\)/, "policy(X)")) { |l, gate| l.gsub(gate, "GATE") }
        constants = stripped.scan(/\b[A-Z][A-Za-z]+(?:::[A-Z][A-Za-z]+)*\b/) - WORKSPACE_OWN - %w[X GATE]
        [ number, line.strip ] if constants.any?
      end
    end

    def source_files(root = "{app,lib}")
      Dir.glob(Rails.root.join("#{root}/**/*.{rb,erb,rake}")).map { |f| f.delete_prefix("#{Rails.root}/") }.sort
    end

    # Code only: full-line comments and ERB comments dropped, string contents
    # blanked, trailing comments removed.
    def code_lines(path)
      source = File.read(Rails.root.join(path))
      source = source.gsub(/<%#.*?%>/m) { |c| "\n" * c.count("\n") } if path.end_with?(".erb")
      source.each_line.with_index(1)
            .reject { |line, _| line.lstrip.start_with?("#") }
            .map { |line, number| [ line.gsub(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/, '""').sub(/\s#\s.*$/, ""), number ] }
    end

    def matches_in(path, pattern)
      code_lines(path).filter_map { |line, number| "#{path}:#{number}: #{line.strip}" if line.match?(pattern) }
    end

    def outbound_associations(model)
      model.constantize.reflect_on_all_associations
           .select { |a| %i[has_many has_one].include?(a.macro) && !a.class_name.start_with?("ActiveStorage") }
    end
  end
end

RSpec.describe "Architecture: Organization & Access does not write downstream data" do
  boundary = ArchitectureSpecs::OrganizationAccessOutboundBoundary

  describe "warehouse access (Inventory & Purchasing)" do
    it "is named only by Inventory & Purchasing code and the classified User lines" do
      allowed = boundary::INVENTORY_FILES.keys + [ boundary::USER_FILE ]
      outside = boundary.source_files.reject { |path| allowed.include?(path) }
                        .flat_map { |path| boundary.matches_in(path, boundary::WAREHOUSE_ACCESS) }
      expect(outside).to be_empty, <<~MSG
        Warehouse access is Inventory & Purchasing data; go through OrganizationAccess::UserWarehouseAccess:
        #{outside.join("\n")}
      MSG
    end

    it "keeps User to its three classified lines (lifecycle, read traversal, the unchanged fail-open rule)" do
      lines = boundary.matches_in(boundary::USER_FILE, boundary::WAREHOUSE_ACCESS).map { |line| line.split(": ", 2).last.strip }
      expect(lines.size).to eq(boundary::USER_LINES.size), lines.inspect
      boundary::USER_LINES.each { |shape| expect(lines.grep(shape)).not_to be_empty, "#{shape.source} is gone — update the exception" }
    end

    it "keeps the Inventory & Purchasing allow-list tight" do
      stale = boundary::INVENTORY_FILES.keys.select do |path|
        !File.exist?(Rails.root.join(path)) || boundary.matches_in(path, boundary::WAREHOUSE_ACCESS).empty?
      end
      expect(stale).to be_empty, "Remove from the allow-list: #{stale.join(', ')}"
    end

    it "the employee controller applies warehouse access only through the contract" do
      code = boundary.code_lines(boundary::CONTROLLER).map(&:first).join
      expect(code).to include("OrganizationAccess::UserWarehouseAccess.assign(user: user, warehouse_ids: warehouse_ids)")
      expect(code.scan("assign_warehouse_access(@user, warehouse_ids)").size).to eq(2) # create and update
    end

    it "the contract names nothing from Inventory & Purchasing" do
      expect(boundary.matches_in(boundary::CONTRACT_FILE, /\bInventory::|\bWarehouse\w*\b(?!_)|\bwarehouse_assignments\b/)).to be_empty
    end

    it "only the composition root and Inventory & Purchasing name the implementation; it is the registered handler" do
      outside = (boundary.source_files + boundary.source_files("config"))
                .reject { |file| file == "app/services/inventory/user_warehouse_assignments.rb" || file == boundary::COMPOSITION_ROOT }
                .flat_map { |file| boundary.matches_in(file, /\bUserWarehouseAssignments\b/) }
      expect(outside).to be_empty, "Unexpected reference to the implementation:\n#{outside.join("\n")}"
      expect(boundary.matches_in(boundary::COMPOSITION_ROOT,
                                 /OrganizationAccess::UserWarehouseAccess\.register\(Inventory::UserWarehouseAssignments\)/)).to be_present
      expect(OrganizationAccess::UserWarehouseAccess.handler).to equal(Inventory::UserWarehouseAssignments)
    end
  end

  describe "inverse associations into other domains (classified, frozen)" do
    boundary::INVERSE_ASSOCIATIONS.each do |model, by_domain|
      it "#{model} holds exactly the classified associations, each to a model of the stated domain" do
        actual = boundary.outbound_associations(model)
        unknown = actual.map(&:class_name).uniq.reject { |name| boundary::DOMAIN_OF.key?(name) }
        expect(unknown).to be_empty, "Classify the owning domain of: #{unknown.join(', ')}"

        grouped = actual.reject { |a| boundary::DOMAIN_OF[a.class_name] == :organization_access }
                        .group_by { |a| boundary::DOMAIN_OF[a.class_name] }
                        .transform_values { |list| list.map(&:name).sort }
        expect(grouped).to eq(by_domain.transform_values(&:sort))
      end
    end
  end

  describe "WorkspaceHelper (UI shell navigation registry)" do
    it "names other domains' models only as policy(Model) gates (plus the classified workspace gates) and writes nothing" do
      offending = boundary.workspace_offending_lines(boundary.code_lines(boundary::WORKSPACE_HELPER))
                          .map { |number, line| "#{boundary::WORKSPACE_HELPER}:#{number}: #{line}" }
      expect(offending).to be_empty, "WorkspaceHelper may only gate on policy(Model):\n#{offending.join("\n")}"

      code = boundary.code_lines(boundary::WORKSPACE_HELPER).map(&:first).join
      expect(code).to include("policy(")
      boundary::WORKSPACE_GATES.each { |gate| expect(code).to include(gate), "#{gate} is no longer read — remove it" }
    end
  end

  describe "self-tests" do
    it "matches warehouse-access internals and not the form parameter or the read rule" do
      [
        "WarehouseAssignment.create!(user: u, warehouse: w)", "user.warehouse_assignments.destroy_all",
        "user.assigned_warehouses << w", "user.assigned_warehouse_ids = ids", "Inventory::UserWarehouseAssignments.assign(**a)"
      ].each { |code| expect(code).to match(boundary::WAREHOUSE_ACCESS), code }
      [
        "ACCOUNT_ATTRIBUTES = [ :active, { assigned_warehouse_ids: [] } ]", "f.collection_check_boxes :assigned_warehouse_ids, w",
        "user.inventory_warehouse_ids", "assigned_warehouse_ids == ids", "OrganizationAccess::UserWarehouseAccess.assign(user: u, warehouse_ids: i)"
      ].each { |code| expect(code).not_to match(boundary::WAREHOUSE_ACCESS), code }
    end

    it "flags a warehouse write planted in Organization & Access code" do
      path = "app/services/organization_access/change_user_role.rb"
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(Rails.root.join(path)).and_return("user.assigned_warehouse_ids = []\n")

      expect(boundary.matches_in(path, boundary::WAREHOUSE_ACCESS)).not_to be_empty
    end

    it "flags a query planted in WorkspaceHelper" do
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(Rails.root.join(boundary::WORKSPACE_HELPER))
        .and_return("visible = policy(StockIssue).index?\nlow = Product.where(active: true).count\n")

      expect(boundary.workspace_offending_lines(boundary.code_lines(boundary::WORKSPACE_HELPER)).map(&:first)).to eq([ 2 ])
    end
  end
end
