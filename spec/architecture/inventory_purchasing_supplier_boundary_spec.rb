require "rails_helper"

# Boundary enforcement for Pilot 6 — Inventory & Purchasing Supplier (M6; see
# docs/architecture/next-pilot-selection.md §21).
#
# Supplier (table suppliers), SupplierPolicy and Inventory::SuppliersController
# are owned by Inventory & Purchasing. Its consumers — Product (default
# supplier), PurchaseRequest, GoodsReceipt, the inventory services, views and
# reports — are internal to the same domain, so Product → Supplier,
# PurchaseRequest → Supplier and GoodsReceipt → Supplier are NOT cross-domain
# edges. M0/M1 found no cross-domain caller, cycle or write; there is no
# boundary object (M2–M5 not needed).
#
# Rules:
# 1. Outside Inventory & Purchasing, nothing names Supplier / SupplierPolicy,
#    a supplier association, a supplier collection or the supplier columns —
#    except the classified exceptions, each limited to its exact current line.
# 2. No code outside Inventory & Purchasing writes a supplier.
#
# Not guarded: route helpers (inventory_suppliers_path …), i18n keys, the
# manage_suppliers permission name (authorization metadata, checked below),
# comments, JavaScript and config/ — as in the other boundary specs.
module ArchitectureSpecs
  module InventoryPurchasingSupplierBoundary
    module_function

    FORBIDDEN = /
      \bSupplier\b                                                     # the model (not SupplierPolicy …)
      | \bSupplierPolicy\b
      | \bSuppliersController\b
      | \.suppliers\b                                                  # business.suppliers
      | \bsuppliers\.\w                                                 # suppliers.destroy_all (receiver-less association call)
      | \b(?:has_many|has_one|belongs_to)\s+:(?:suppliers?|default_supplier)\b
      | \bdefault_supplier(?:_id)?\b
      | \bsupplier_id\b
    /x

    # Writing a supplier, from anywhere outside Inventory & Purchasing.
    WRITE = /
      \bSupplier\.(?:create|new|insert|upsert|update_all|delete_all|destroy_all|find_or_create_by)
      | \.suppliers\.(?:create|build|new|update_all|delete_all|destroy_all|find_or_create_by)
      | \bsupplier\.(?:update|save|destroy|delete|assign_attributes)
    /x

    # Inventory & Purchasing code that references suppliers.
    INVENTORY_PURCHASING_DIRS = %w[
      app/controllers/inventory/
      app/views/inventory/
      app/services/inventory/
    ].freeze

    INVENTORY_PURCHASING_FILES = {
      "app/models/inventory_purchasing/supplier.rb" => "the model itself (folder collapsed: top-level constant, M7)",
      "app/models/product.rb"          => "IP: default supplier (same-business validated, SEC-P6-2)",
      "app/models/purchase_request.rb" => "IP: purchase requests own supplier selection",
      "app/models/goods_receipt.rb"    => "IP: receipts reference the supplier (same-business validated, SEC-P6-1)",
      "app/policies/supplier_policy.rb" => "IP: supplier authorization",
      "app/helpers/inventory_helper.rb" => "IP: product options carry the default supplier for receipt prefill"
    }.freeze

    # Classified exceptions outside the domain, each limited to its exact line.
    EXCEPTIONS = {
      "app/models/business.rb" => {
        kind: "lifecycle (Organization & Access inverse association)",
        shapes: [ /\Ahas_many :suppliers,\s+dependent: :destroy\z/ ]
      },
      "app/helpers/workspace_helper.rb" => {
        kind: "navigation (UI shell: the Suppliers menu entry, gated by SupplierPolicy#index?)",
        shapes: [ /\A\[ :suppliers,\s+t\("KEY"\),\s+inventory_suppliers_path,\s+:catalog,\s+false, policy\(Supplier\)\.index\? \],\z/ ]
      }
    }.freeze

    # Other domains' code (module-boundaries.md §4–§9), for per-domain checks.
    DOMAIN_GLOBS = {
      "Organization & Access" => %w[
        app/models/{business,branch,user,user_audit_log}.rb app/models/organization_access/**/*.rb
        app/services/organization_access/**/*.rb app/services/{employee_scope,branch_scope}.rb
        app/controllers/admin/{branches,permission_roles,settings}_controller.rb app/policies/{branch,permission_role}_policy.rb
      ],
      "Workforce" => %w[
        app/models/workforce/**/*.rb app/models/{shift,shift_assignment,shift_template,employee_request}.rb
        app/services/{shifts,requests,employee,employee_data_requests,performance,workforce}/**/*.rb
        app/controllers/{shift_assignments,employee_requests}_controller.rb
      ],
      "Attendance & Payroll" => %w[
        app/models/attendance_payroll/**/*.rb app/models/{advance,attendance_record,payroll_period,payroll_entry,salary_profile}.rb
        app/services/{payroll,attendance,salary}/**/*.rb app/controllers/{payroll_periods,attendance_records}_controller.rb
      ],
      "Finance & Sales" => %w[
        app/models/finance_sales/**/*.rb app/models/{financial_settlement,custody_account,custody_transaction,daily_reconciliation}.rb
        app/services/finance/**/*.rb app/services/financial_settlement_service.rb
        app/controllers/finance/**/*.rb app/views/finance/**/*.erb
      ],
      "Reporting" => %w[
        app/services/dashboard/**/*.rb app/services/finance/dashboard/**/*.rb app/services/finance/reports/**/*.rb
        app/controllers/{dashboard,operations_dashboard}_controller.rb
        app/controllers/finance/{dashboard,reports}_controller.rb app/views/finance/dashboard/**/*.erb
      ]
    }.freeze

    def source_files
      Dir.glob(Rails.root.join("{app,lib}/**/*.{rb,erb,rake}")).map { |f| f.delete_prefix("#{Rails.root}/") }.sort
    end

    def domain_files(domain)
      DOMAIN_GLOBS.fetch(domain).flat_map { |glob| Dir.glob(Rails.root.join(glob)) }
                  .map { |f| f.delete_prefix("#{Rails.root}/") }.uniq.sort
    end

    def inventory_purchasing?(path)
      INVENTORY_PURCHASING_FILES.key?(path) || INVENTORY_PURCHASING_DIRS.any? { |dir| path.start_with?(dir) }
    end

    # Full-line comments, ERB comments and t(...) i18n keys are ignored.
    def code_lines(path)
      source = File.read(Rails.root.join(path))
      source = source.gsub(/<%#.*?%>/m) { |c| "\n" * c.count("\n") } if path.end_with?(".erb")
      source.each_line.with_index(1)
            .reject { |line, _| line.lstrip.start_with?("#") }
            .map { |line, number| [ line.gsub(/\b(?:I18n\.)?t\(\s*(["'])[^"']*\1/, 't("KEY"'), number ] }
    end

    def matches_in(path, pattern)
      code_lines(path).filter_map { |line, number| [ number, line.strip ] if line.match?(pattern) }
    end

    def violations_in(path)
      shapes = EXCEPTIONS.dig(path, :shapes) || []
      matches_in(path, FORBIDDEN).reject { |_, line| shapes.any? { |shape| line.match?(shape) } }
                                 .map { |number, line| "#{path}:#{number}: #{line}" }
    end
  end
end

RSpec.describe "Architecture: Inventory & Purchasing Supplier boundary" do
  boundary = ArchitectureSpecs::InventoryPurchasingSupplierBoundary

  it "Supplier ownership is explicit: model, policy and controller live in Inventory & Purchasing" do
    expect(Supplier.name).to eq("Supplier") # resolving the constant triggers the autoload
    expect(Object.const_source_location("Supplier").first).to eq(Rails.root.join("app/models/inventory_purchasing/supplier.rb").to_s)
    expect(Inventory::SuppliersController.ancestors).to include(Inventory::BaseController)
    expect(Pundit::PolicyFinder.new(Supplier).policy).to eq(SupplierPolicy)
  end

  it "nothing outside Inventory & Purchasing references suppliers, beyond the classified exceptions" do
    violations = boundary.source_files.reject { |path| boundary.inventory_purchasing?(path) }
                         .flat_map { |path| boundary.violations_in(path) }
    expect(violations).to be_empty, <<~MSG
      Supplier is owned by Inventory & Purchasing; unexpected reference from another domain:
      #{violations.join("\n")}
      Go through Inventory & Purchasing, or classify a new exception in next-pilot-selection.md §21.
    MSG
  end

  it "no code outside Inventory & Purchasing writes a supplier" do
    writes = boundary.source_files.reject { |path| boundary.inventory_purchasing?(path) }
                     .flat_map { |path| boundary.matches_in(path, boundary::WRITE).map { |n, l| "#{path}:#{n}: #{l}" } }
    expect(writes).to be_empty
  end

  boundary::DOMAIN_GLOBS.each_key do |domain|
    it "#{domain} code neither owns nor mutates Supplier behaviour" do
      expect(boundary.domain_files(domain)).not_to be_empty
      found = boundary.domain_files(domain).flat_map { |path| boundary.violations_in(path) }
      expect(found).to be_empty, "#{domain}:\n#{found.join("\n")}"
    end
  end

  it "keeps the allow-list and exceptions tight (every entry exists and is still needed)" do
    stale = (boundary::INVENTORY_PURCHASING_FILES.keys + boundary::EXCEPTIONS.keys).select do |path|
      !File.exist?(Rails.root.join(path)) || boundary.matches_in(path, boundary::FORBIDDEN).empty?
    end
    expect(stale).to be_empty, "Remove: #{stale.join(', ')}"

    unused = boundary::INVENTORY_PURCHASING_DIRS.reject do |dir|
      boundary.source_files.any? { |path| path.start_with?(dir) && boundary.matches_in(path, boundary::FORBIDDEN).any? }
    end
    expect(unused).to be_empty
  end

  it "the manage_suppliers permission is authorization metadata in the catalogue (requires view_inventory)" do
    expect(PermissionRole::ALL_PERMISSIONS).to include("manage_suppliers")
    expect(PermissionRole::PERMISSION_DEPENDENCIES.fetch("manage_suppliers")).to eq(%w[view_inventory])
  end

  it "the Organization & Access inverse association stays a lifecycle association only" do
    reflection = Business.reflect_on_association(:suppliers)
    expect(reflection).to have_attributes(macro: :has_many, class_name: "Supplier")
    expect(reflection.options).to eq(dependent: :destroy)
  end

  describe "self-tests (planted probes)" do
    def plant(path, content)
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with(Rails.root.join(path)).and_return(content)
    end

    {
      "Organization & Access" => "app/services/organization_access/permission_grants.rb",
      "Workforce"             => "app/services/shifts/assigner.rb",
      "Attendance & Payroll"  => "app/services/payroll/approver.rb",
      "Finance & Sales"       => "app/services/finance/expense_approval.rb",
      "Reporting"             => "app/services/finance/dashboard/insights_generator.rb"
    }.each do |domain, path|
      it "catches a supplier read planted in #{domain}" do
        plant(path, "names = business.suppliers.ordered.pluck(:name)\n")
        expect(boundary.violations_in(path)).not_to be_empty
      end
    end

    it "catches a supplier write planted outside the domain, and a widened exception" do
      plant("app/services/finance/expense_approval.rb", "Supplier.create!(business: b, name: n)\nsupplier.update!(name: n)\n")
      expect(boundary.matches_in("app/services/finance/expense_approval.rb", boundary::WRITE).size).to eq(2)

      plant("app/models/business.rb", "has_many :suppliers, dependent: :destroy\nsuppliers.destroy_all\n")
      expect(boundary.violations_in("app/models/business.rb")).to eq([ "app/models/business.rb:2: suppliers.destroy_all" ])
    end

    it "does not flag harmless references: route helpers, i18n keys, the permission name, comments" do
      plant("app/helpers/application_helper.rb",
            "link_to t(\"nav.inventory_suppliers\"), inventory_suppliers_path\n" \
            "user.can?(:manage_suppliers)\n# Supplier is IP-owned\nsupplier_financials_available?\n")
      expect(boundary.violations_in("app/helpers/application_helper.rb")).to be_empty
    end

    it "treats Product / PurchaseRequest / GoodsReceipt → Supplier as internal" do
      %w[app/models/product.rb app/models/purchase_request.rb app/models/goods_receipt.rb].each do |path|
        expect(boundary.inventory_purchasing?(path)).to be(true)
        expect(boundary.matches_in(path, boundary::FORBIDDEN)).not_to be_empty
      end
    end
  end
end
