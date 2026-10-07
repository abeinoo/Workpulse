require "rails_helper"

# Boundary enforcement for Pilot 7 — Inventory & Purchasing Product Catalogue
# (M6; see docs/architecture/next-pilot-selection.md §22).
#
# Brand (table brands) and ProductCategory (table product_categories), their
# policies and Inventory::BrandsController / Inventory::ProductCategoriesController
# are owned by Inventory & Purchasing. Product (brand / category references),
# Inventory::Imports::ProductImporter (find-or-create by name) and the inventory
# controllers, views and reports are internal to the same domain, so
# Product → Brand / ProductCategory is NOT a cross-domain edge. M0/M1 found no
# cross-domain caller, cycle or write; there is no boundary object (M2–M5 not
# needed).
#
# Rules:
# 1. Outside Inventory & Purchasing, nothing names Brand / ProductCategory, their
#    policies or controllers, a brand / category association, collection or
#    column — except the classified exceptions, each limited to its exact
#    current line shape: the Organization & Access lifecycle association, the
#    workspace navigation, and the Reporting read in Finance::Reports::ExpenseSources.
# 2. No code outside Inventory & Purchasing writes a brand or a category —
#    directly, through a business collection, or by assigning one to a record.
#    A `category.save / update / destroy` counts only in a file that names the
#    catalogue (elsewhere `category` is e.g. Finance's ExpenseCategory).
#
# Not guarded: route helpers (inventory_brands_path …), i18n keys, the inventory
# permission names (authorization metadata, checked below), comments, CSS class
# names, JavaScript, config/ and db/seeds.rb — as in the other boundary specs.
module ArchitectureSpecs
  module InventoryPurchasingProductCatalogueBoundary
    module_function

    FORBIDDEN = /
      \b(?:Brand|ProductCategory)\b                                      # the models (not BrandPolicy …)
      | \b(?:BrandPolicy|ProductCategoryPolicy|BrandsController|ProductCategoriesController)\b
      | \.(?:brands?|product_categor(?:y|ies))\b                         # business.brands, product.product_category
      | \b(?:brands|product_categories)\.\w                              # receiver-less association call
      | :(?:brands?|product_categor(?:y|ies))\b                          # associations, includes(:brand)
      | \b(?:brand|product_category)_id\b
      | \b(?:brand|product_category):\s                                  # attributes passed to a write
    /x

    WRITE_VERBS = "create|build|new|insert|upsert|update|delete|destroy|find_or_create_by|find_or_initialize_by|create_or_find_by"

    # Writing a brand or a category, from anywhere outside Inventory & Purchasing.
    WRITE = /
      \b(?:Brand|ProductCategory)\.(?:#{WRITE_VERBS})
      | \b(?:brands|product_categories)\.(?:#{WRITE_VERBS})              # business.brands.create!, brands.destroy_all
      | \b(?:brand|product_category)\.(?:update|save|destroy|delete|assign_attributes|toggle|touch|increment|decrement)
      | \.(?:brand|product_category)(?:_id)?\s*=(?![=~>])                # product.brand = … (a local `brand = …` is not a write)
      | \b(?:brand|product_category)(?:_id)?:\s                          # Product.create!(brand: …)
    /x

    # Ambiguous receiver: only a write in a file that also names the catalogue.
    CONTEXTUAL_WRITE = /\bcategory\.(?:update|save|destroy|delete|assign_attributes|toggle|touch)/

    # Inventory & Purchasing code that references the catalogue.
    INVENTORY_PURCHASING_DIRS = %w[
      app/controllers/inventory/
      app/views/inventory/
      app/services/inventory/
    ].freeze

    INVENTORY_PURCHASING_FILES = {
      "app/models/inventory_purchasing/brand.rb"            => "the model itself (folder collapsed: top-level constant, M7)",
      "app/models/inventory_purchasing/product_category.rb" => "the model itself (folder collapsed: top-level constant, M7)",
      "app/models/product.rb"                               => "IP: brand / category references (same-business validated, SEC-P6-4/5)",
      "app/policies/brand_policy.rb"                        => "IP: brand authorization",
      "app/policies/product_category_policy.rb"             => "IP: category authorization"
    }.freeze

    # Classified exceptions outside the domain, each limited to its exact line.
    EXCEPTIONS = {
      "app/models/business.rb" => {
        kind: "lifecycle (Organization & Access inverse association)",
        shapes: [ /\Ahas_many :brands,\s+dependent: :destroy\z/, /\Ahas_many :product_categories,\s+dependent: :destroy\z/ ]
      },
      "app/helpers/workspace_helper.rb" => {
        kind: "navigation (UI shell: the inventory Settings entry, gated by the catalogue policies' index?)",
        shapes: [ /\A\[ :settings,\s+t\("KEY"\),\s+inventory_settings_path,\s+:settings,\s+false, policy\(ProductCategory\)\.index\? \|\| policy\(Brand\)\.index\? \|\| policy\(WarehouseBranchSupply\)\.index\? \]\z/ ]
      },
      "app/services/finance/reports/expense_sources.rb" => {
        kind: "Reporting read (module-boundaries.md §9): a consumed product's category name in the expense breakdown",
        shapes: [
          /\Aproducts = Product\.where\(id: totals\.keys\.map\(&:second\)\)\.includes\(:product_category\)\.index_by\(&:id\)\z/,
          /\Acategory: product&\.product_category&\.name,\z/
        ]
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
        app/views/finance/reports/**/*.erb app/views/dashboard/**/*.erb
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

    # Writes are never excepted — the classified exceptions are read-only.
    def writes_in(path)
      found = matches_in(path, WRITE)
      found |= matches_in(path, CONTEXTUAL_WRITE) if matches_in(path, FORBIDDEN).any?
      found.sort.map { |number, line| "#{path}:#{number}: #{line}" }
    end

    def external_files
      source_files.reject { |path| inventory_purchasing?(path) }
    end
  end
end

RSpec.describe "Architecture: Inventory & Purchasing product catalogue boundary" do
  boundary = ArchitectureSpecs::InventoryPurchasingProductCatalogueBoundary

  it "catalogue ownership is explicit: models, policies and controllers live in Inventory & Purchasing" do
    { "Brand" => [ BrandPolicy, Inventory::BrandsController ],
      "ProductCategory" => [ ProductCategoryPolicy, Inventory::ProductCategoriesController ] }.each do |name, (policy, controller)|
      model = name.constantize # resolving the constant triggers the autoload
      expect(boundary.inventory_purchasing?(Object.const_source_location(name).first.delete_prefix("#{Rails.root}/"))).to be(true)
      expect(Pundit::PolicyFinder.new(model).policy).to eq(policy)
      expect(controller.ancestors).to include(Inventory::BaseController)
    end
  end

  it "nothing outside Inventory & Purchasing references the catalogue, beyond the classified exceptions" do
    violations = boundary.external_files.flat_map { |path| boundary.violations_in(path) }
    expect(violations).to be_empty, <<~MSG
      Brand / ProductCategory are owned by Inventory & Purchasing; unexpected reference from another domain:
      #{violations.join("\n")}
      Go through Inventory & Purchasing, or classify a new exception in next-pilot-selection.md §22.
    MSG
  end

  it "no code outside Inventory & Purchasing writes a brand or a category (the exceptions included)" do
    writes = boundary.external_files.flat_map { |path| boundary.writes_in(path) }
    expect(writes).to be_empty, <<~MSG
      Only Inventory & Purchasing may create, update, destroy or assign a brand / product category:
      #{writes.join("\n")}
    MSG
  end

  boundary::DOMAIN_GLOBS.each_key do |domain|
    it "#{domain} code neither owns nor mutates catalogue behaviour" do
      expect(boundary.domain_files(domain)).not_to be_empty
      found = boundary.domain_files(domain).flat_map { |path| boundary.violations_in(path) + boundary.writes_in(path) }
      expect(found).to be_empty, "#{domain}:\n#{found.join("\n")}"
    end
  end

  it "keeps the allow-list and exceptions tight (every entry exists and is still needed)" do
    stale = (boundary::INVENTORY_PURCHASING_FILES.keys + boundary::EXCEPTIONS.keys).select do |path|
      !File.exist?(Rails.root.join(path)) || boundary.matches_in(path, boundary::FORBIDDEN).empty?
    end
    expect(stale).to be_empty, "Remove: #{stale.join(', ')}"

    unmatched_shapes = boundary::EXCEPTIONS.flat_map do |path, exception|
      lines = boundary.matches_in(path, boundary::FORBIDDEN).map(&:last)
      exception[:shapes].reject { |shape| lines.any? { |line| line.match?(shape) } }.map { |shape| "#{path}: #{shape.source}" }
    end
    expect(unmatched_shapes).to be_empty, "Unused exception shapes:\n#{unmatched_shapes.join("\n")}"

    unused = boundary::INVENTORY_PURCHASING_DIRS.reject do |dir|
      boundary.source_files.any? { |path| path.start_with?(dir) && boundary.matches_in(path, boundary::FORBIDDEN).any? }
    end
    expect(unused).to be_empty
  end

  it "the Reporting exception is read-only: ExpenseSources only reads (no write, no callback) and is Reporting code" do
    path = "app/services/finance/reports/expense_sources.rb"
    expect(boundary.domain_files("Reporting")).to include(path)
    expect(boundary.writes_in(path)).to be_empty
    expect(boundary.matches_in(path, /\b(?:save|update|destroy|delete|update_columns?|update_all|touch)\b[!(]?/)).to be_empty
  end

  it "the permissions gating the catalogue are authorization metadata in the catalogue (manage_products requires view_inventory)" do
    expect(PermissionRole::ALL_PERMISSIONS).to include("view_inventory", "manage_inventory", "manage_products")
    expect(PermissionRole::PERMISSION_DEPENDENCIES.fetch("manage_products")).to eq(%w[view_inventory])
  end

  it "the Organization & Access inverse associations stay lifecycle associations only" do
    { brands: "Brand", product_categories: "ProductCategory" }.each do |name, class_name|
      reflection = Business.reflect_on_association(name)
      expect(reflection).to have_attributes(macro: :has_many, class_name: class_name)
      expect(reflection.options).to eq(dependent: :destroy)
    end
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
      it "catches a catalogue read planted in #{domain}" do
        plant(path, "names = business.brands.ordered.pluck(:name)\ncats = ProductCategory.active.count\n")
        expect(boundary.violations_in(path).size).to eq(2)
      end
    end

    {
      "Brand.create!"           => "Brand.create!(business: b, name: n)",
      "brand.update!"           => "brand = Brand.find(id)\nbrand.update!(name: n)",
      "brand.destroy!"          => "Brand.find(id).tap { |brand| brand.destroy! }",
      "ProductCategory.create!" => "ProductCategory.create!(business: b, name: n)",
      "category.update!"        => "category = ProductCategory.find(id)\ncategory.update!(active: false)",
      "category.destroy!"       => "category = business.product_categories.find(id)\ncategory.destroy!",
      "business.brands.create!" => "business.brands.create!(name: n)",
      "product.brand ="         => "product.brand = other_brand\nproduct.save!",
      "Product.create!(product_category: …)" => "Product.create!(business: b, name: n, sku: s, product_category: c)",
      "brand.update_columns"    => "brand.update_columns(name: n)"
    }.each do |label, code|
      it "catches a planted #{label} outside the domain" do
        path = "app/services/finance/expense_approval.rb"
        plant(path, "#{code}\n")
        expect(boundary.writes_in(path)).not_to be_empty
      end
    end

    it "catches a widened exception: a write next to the OA association or inside the Reporting read" do
      plant("app/models/business.rb", "has_many :brands,               dependent: :destroy\nbrands.destroy_all\n")
      expect(boundary.violations_in("app/models/business.rb")).to eq([ "app/models/business.rb:2: brands.destroy_all" ])
      expect(boundary.writes_in("app/models/business.rb")).to eq([ "app/models/business.rb:2: brands.destroy_all" ])

      path = "app/services/finance/reports/expense_sources.rb"
      plant(path, "category: product&.product_category&.name,\nproduct.product_category.update!(name: n)\n")
      expect(boundary.violations_in(path)).to eq([ "#{path}:2: product.product_category.update!(name: n)" ])
      expect(boundary.writes_in(path)).not_to be_empty
    end

    it "a local variable named brand / category is not a write by itself (its reference still is a violation)" do
      path = "app/services/finance/expense_approval.rb"
      plant(path, "brand = Brand.find(id)\n")
      expect(boundary.writes_in(path)).to be_empty
      expect(boundary.violations_in(path)).not_to be_empty
    end

    it "does not flag harmless references: route helpers, i18n keys, permission names, CSS classes, prose, comments, expense categories" do
      plant("app/helpers/application_helper.rb",
            "link_to t(\"inventory.brands.title\"), inventory_brands_path\n" \
            "link_to t(\"nav.inventory_settings\"), edit_inventory_product_category_path(id)\n" \
            "user.can?(:manage_products)\n# Brand is IP-owned\n" \
            "content_tag(:span, class: \"empty-icon empty-icon--brand sidebar__brand\")\n" \
            "\"a brand new deposit\"\n")
      expect(boundary.violations_in("app/helpers/application_helper.rb")).to be_empty
      expect(boundary.writes_in("app/helpers/application_helper.rb")).to be_empty

      expect(boundary.writes_in("app/controllers/finance/expense_categories_controller.rb")).to be_empty
      expect(boundary.matches_in("app/controllers/finance/expense_categories_controller.rb", boundary::CONTEXTUAL_WRITE)).not_to be_empty
    end

    it "treats Product → Brand / ProductCategory and ProductImporter as internal" do
      %w[app/models/product.rb app/services/inventory/imports/product_importer.rb].each do |path|
        expect(boundary.inventory_purchasing?(path)).to be(true)
        expect(boundary.matches_in(path, boundary::FORBIDDEN)).not_to be_empty
      end
      expect(boundary.writes_in("app/services/inventory/imports/product_importer.rb")).not_to be_empty
    end
  end
end
