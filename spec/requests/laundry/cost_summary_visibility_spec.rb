require "rails_helper"
require "csv"

# Security fix: the laundry operating-cost report must not expose payroll (or
# any figure payroll can be recovered from) without view_payroll, nor
# stock-issue line details the viewer could not open themselves, and it must
# refuse to report when more than one active laundry branch exists.
RSpec.describe "Laundry cost summary — visibility", type: :request do
  let(:business)        { create(:business) }
  let!(:sales_branch)   { create(:branch, business: business, branch_type: "sales", name: "Sales Branch Kappa") }
  let!(:laundry_branch) { create(:branch, business: business, branch_type: "laundry", name: "Zeta Laundry Hub") }
  let(:owner)           { create(:user, :owner, business: business) }
  let(:actor)           { create(:user, business: business) }
  let(:towel_type)      { business.towel_types.create!(name: "Bath Towel") }

  let(:from) { Date.current.beginning_of_month }
  let(:to)   { Date.current.end_of_month }

  let!(:wh_a) { business.warehouses.create!(name: "Warehouse Alpha") }
  let!(:wh_b) { business.warehouses.create!(name: "Warehouse Bravo") }
  let!(:product_a) do
    business.products.create!(name: "Alpha Soap", sku: "ALP-1", unit_of_measure: "kg",
                              initial_cost_price: 23, average_cost_price: 23)
  end
  let!(:product_b) do
    business.products.create!(name: "Bravo Bleach", sku: "BRV-1", unit_of_measure: "kg",
                              initial_cost_price: 37, average_cost_price: 37)
  end

  # Known amounts:
  #   standard cost  100 towels x 1.5        = 150.00
  #   payroll        net salary              = 7,777.00
  #   expenses       direct                  = 411.00
  #   materials      3 x 23 (A) + 2 x 37 (B) = 69 + 74 = 143.00
  #   actual         7,777 + 411 + 143       = 8,331.00
  #   variance       150 - 8,331             = -8,181.00
  #   per towel      8,331 / 100             = 83.31
  let(:payroll_figures)     { %w[7,777 8,331 8,181 83.31] }
  let(:csv_payroll_figures) { %w[7777 8331 8181] }

  let!(:issue_a) { issue!(warehouse: wh_a, product: product_a, quantity: 3) }
  let!(:issue_b) { issue!(warehouse: wh_b, product: product_b, quantity: 2) }
  let!(:payroll_period) do
    create(:payroll_period, :finalized, business: business, branch: nil,
                                        period_year: from.year, period_month: from.month)
  end

  before do
    business.laundry_standard_cost_rates.create!(towel_type: towel_type, cost_per_towel: 1.5, effective_from: 1.year.ago)
    receive_towels!(100)

    laundry_worker = create(:user, business: business)
    create(:shift_assignment, business: business, user: laundry_worker, branch: laundry_branch,
                              effective_from: from - 1.month, effective_to: nil)
    create(:payroll_entry, payroll_period: payroll_period, user: laundry_worker, net_salary: 7777)

    create(:expense, :approved, business: business, branch: laundry_branch,
                                expense_category: create(:expense_category, business: business),
                                amount: 411, expense_date: from + 2.days)
  end

  def user_with(*perms, warehouses: [], scopes: {})
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms, permission_scopes: scopes)
    create(:user, business: business).tap do |u|
      u.update_column(:permission_role_id, role.id)
      warehouses.each { |wh| u.assigned_warehouses << wh }
    end
  end

  def issue!(warehouse:, product:, quantity:)
    receipt = business.goods_receipts.build(warehouse: warehouse, received_on: from + 1.day)
    receipt.items.build(product: product, quantity: 50, unit_cost: product.average_cost_price)
    Inventory::GoodsReceiptPoster.new(receipt).call

    issue = business.stock_issues.build(warehouse: warehouse, branch: laundry_branch, issued_on: from + 2.days)
    issue.items.build(product: product, quantity: quantity)
    approve_and_post_stock_issue(issue).issue
  end

  def receive_towels!(confirmed)
    Laundry::TowelAdjuster.new(actor: actor).call(towel_type: towel_type, branch: sales_branch, status: "clean",
                                                   adjustment_quantity: confirmed + 10, reason: "test setup")
    transfer = Laundry::TowelTransferCreator.create(actor: actor, params: {
      source_branch_id: sales_branch.id, destination_branch_id: laundry_branch.id, towel_status: "dirty",
      items_attributes: [ { towel_type_id: towel_type.id, declared_quantity: confirmed } ]
    }).transfer
    Laundry::TowelTransferCreator.new(transfer).dispatch(actor: actor)
    Laundry::TowelTransferCreator.new(transfer.reload)
                                 .receive(actor: actor, confirmed_quantities: { transfer.items.first.id => confirmed })
  end

  def get_report(format: nil)
    get laundry_reports_cost_summary_path(format: format, from: from.iso8601, to: to.iso8601)
  end

  def csv_rows
    CSV.parse(response.body.delete_prefix(Finance::Reports::CsvExporter::BOM))
  end

  def t_cost(key) = I18n.t("laundry.reports.cost_summary.#{key}")

  describe "payroll figures (HTML)" do
    it "shows the owner every payroll-dependent figure" do
      sign_in owner
      get_report

      expect(response).to have_http_status(:ok)
      payroll_figures.each { |figure| expect(response.body).to include(figure) }
      expect(response.body).to include(payroll_period.period_label)
      expect(response.body).not_to include(t_cost("payroll_restricted"))
    end

    # Payroll cost needs view_payroll with the laundry branch inside its scope
    # (Finance::PayrollCostAccess, decision of 2026-10-19).
    it "shows a view_payroll holder every payroll-dependent figure" do
      sign_in user_with("view_laundry_cost_reports", "view_payroll", scopes: { "view_payroll" => "business" })
      get_report

      payroll_figures.each { |figure| expect(response.body).to include(figure) }
      expect(response.body).to include(t_cost("cards.payroll_cost"), t_cost("cards.total_actual_cost"),
                                       t_cost("cards.coverage_variance"), t_cost("cards.actual_cost_per_towel"))
    end

    it "withholds them from a view_payroll holder whose scope does not cover the laundry branch" do
      outsider = user_with("view_laundry_cost_reports", "view_payroll") # default scope: managed branches — none
      create(:branch, business: business).update_column(:branch_manager_id, outsider.id)
      sign_in outsider
      get_report

      expect(response.body).to include(t_cost("payroll_restricted"))
      payroll_figures.each { |figure| expect(response.body).not_to include(figure) }
    end

    it "shows them to the laundry branch's manager (default view_payroll scope)" do
      manager = user_with("view_laundry_cost_reports", "view_payroll")
      laundry_branch.update_column(:branch_manager_id, manager.id)
      sign_in manager
      get_report

      payroll_figures.each { |figure| expect(response.body).to include(figure) }
    end

    it "withholds payroll and every payroll-derived figure without view_payroll, keeping the independent ones" do
      sign_in user_with("view_laundry_cost_reports")
      get_report

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(t_cost("payroll_restricted"))

      # Nowhere in the source — not in hidden elements, attributes or links.
      payroll_figures.each { |figure| expect(response.body).not_to include(figure) }
      expect(response.body).not_to include(payroll_period.period_label)
      expect(response.body).not_to include(t_cost("cards.payroll_cost"), t_cost("cards.total_actual_cost"),
                                           t_cost("cards.coverage_variance"), t_cost("cards.actual_cost_per_towel"),
                                           t_cost("payroll_periods_included"))

      # Independent components remain: standard cost, expenses, materials.
      expect(response.body).to include("150.00", "411.00", "143.00")
    end

    it "leaves no displayed total from which payroll could be recovered by arithmetic" do
      sign_in user_with("view_laundry_cost_reports")
      get_report

      amounts = response.body.scan(/(?:SAR|SR|\$|€|£)?\s?(-?[\d,]+\.\d{2,4})/).flatten
                         .map { |s| BigDecimal(s.delete(",")) }.uniq
      # Any sum or difference of two displayed amounts must not reveal payroll
      # or the payroll-inclusive totals.
      sensitive = [ 7777, 8331, -8181, 8181 ].map { |n| BigDecimal(n) }
      combos = amounts + amounts.product(amounts).flat_map { |a, b| [ a + b, a - b ] }
      expect(combos & sensitive).to be_empty
    end

    %w[en ar].each do |locale|
      it "renders the payroll-restricted notice without missing translations in #{locale}" do
        viewer = user_with("view_laundry_cost_reports")
        viewer.update!(preferred_locale: locale)
        sign_in viewer
        get_report

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("Translation missing")
        expect(response.body).to include(I18n.t("laundry.reports.cost_summary.payroll_restricted", locale: locale))
        expect(response.body).to include(I18n.t("laundry.reports.cost_summary.material_details.withheld", locale: locale))
      end
    end
  end

  describe "payroll figures (CSV)" do
    it "keeps the payroll rows and their values for a view_payroll holder" do
      sign_in user_with("view_laundry_cost_reports", "view_payroll", scopes: { "view_payroll" => "business" })
      get_report(format: :csv)

      expect(response).to have_http_status(:ok)
      categories = csv_rows.drop(1).map(&:first)
      expect(categories).to eq([ t_cost("payroll_cost"), t_cost("direct_expenses"), t_cost("material_cost"),
                                 t_cost("total_actual_cost"), t_cost("standard_branch_cost"),
                                 t_cost("coverage_variance") ])
      amounts = csv_rows.drop(1).to_h { |row| [ row[0], BigDecimal(row[1]) ] }
      expect(amounts[t_cost("payroll_cost")]).to eq(7777)
      expect(amounts[t_cost("total_actual_cost")]).to eq(8331)
      expect(amounts[t_cost("coverage_variance")]).to eq(-8181)
      expect(amounts[t_cost("standard_branch_cost")]).to eq(150)
    end

    it "omits the payroll row and every payroll-derived row without view_payroll" do
      sign_in user_with("view_laundry_cost_reports")
      get_report(format: :csv)

      expect(response).to have_http_status(:ok)
      categories = csv_rows.drop(1).map(&:first)
      expect(categories).to eq([ t_cost("direct_expenses"), t_cost("material_cost"), t_cost("standard_branch_cost") ])
      csv_payroll_figures.each { |figure| expect(response.body).not_to include(figure) }
    end

    it "never contains stock-issue line details, even for the owner" do
      sign_in owner
      get_report(format: :csv)

      [ issue_a.issue_number, issue_b.issue_number, "Alpha Soap", "Bravo Bleach",
        "Warehouse Alpha", "Warehouse Bravo" ].each { |detail| expect(response.body).not_to include(detail) }
    end

    # Existing empty-state contract (unchanged by the fix): the CSV is still
    # served, with the header and every category row, but no amounts at all.
    it "serves the header and all category rows with blank amounts when no active laundry branch exists" do
      laundry_branch.update_column(:active, false)
      sign_in user_with("view_laundry_cost_reports", "view_payroll")
      get_report(format: :csv)

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/csv")
      header, *rows = csv_rows
      expect(header).to eq([ t_cost("csv.category"), t_cost("csv.amount"), t_cost("csv.period") ])
      expect(rows.map(&:first)).to eq([ t_cost("payroll_cost"), t_cost("direct_expenses"), t_cost("material_cost"),
                                        t_cost("total_actual_cost"), t_cost("standard_branch_cost"),
                                        t_cost("coverage_variance") ])
      expect(rows.map { |row| row[1] }).to all(be_nil)
      expect(rows.map(&:last).uniq).to eq([ "#{from.iso8601} - #{to.iso8601}" ])
      (csv_payroll_figures + %w[150 411 143 69 74]).each { |figure| expect(response.body).not_to include(figure) }
    end

    it "exports Arabic labels, still withholds payroll rows without view_payroll and has no line details" do
      viewer = user_with("view_laundry_cost_reports")
      viewer.update!(preferred_locale: "ar")
      sign_in viewer
      get_report(format: :csv)

      expect(response).to have_http_status(:ok)
      ar = ->(key) { I18n.t("laundry.reports.cost_summary.#{key}", locale: :ar) }
      header, *rows = csv_rows
      expect(header).to eq([ ar.("csv.category"), ar.("csv.amount"), ar.("csv.period") ])
      expect(rows.map(&:first)).to eq([ ar.("direct_expenses"), ar.("material_cost"), ar.("standard_branch_cost") ])
      expect(rows.to_h { |row| [ row[0], BigDecimal(row[1]) ] }).to eq(
        ar.("direct_expenses") => 411, ar.("material_cost") => 143, ar.("standard_branch_cost") => 150
      )
      [ ar.("payroll_cost"), ar.("total_actual_cost"), ar.("coverage_variance") ].each do |label|
        expect(response.body).not_to include(label)
      end
      csv_payroll_figures.each { |figure| expect(response.body).not_to include(figure) }
      [ issue_a.issue_number, issue_b.issue_number, "Alpha Soap", "Bravo Bleach",
        "Warehouse Alpha", "Warehouse Bravo" ].each { |detail| expect(response.body).not_to include(detail) }
    end
  end

  describe "stock-issue details" do
    def expect_line_hidden(issue, product:, warehouse:, unit_cost:, quantity:)
      expect(response.body).not_to include(issue.issue_number)
      expect(response.body).not_to include(inventory_stock_issue_path(issue))
      expect(response.body).not_to include(product, warehouse)
      expect(response.body).not_to match(/(?<![\d,.])#{Regexp.escape(unit_cost)}/)
      expect(response.body).not_to match(%r{<td[^>]*>#{quantity}</td>})
    end

    it "shows a warehouse-A user only A's details, with the aggregate and a withheld notice" do
      sign_in user_with("view_laundry_cost_reports", "view_inventory", warehouses: [ wh_a ])
      get_report

      expect(response.body).to include(issue_a.issue_number, inventory_stock_issue_path(issue_a), "Alpha Soap",
                                       "Warehouse Alpha", "23.00")
      expect_line_hidden(issue_b, product: "Bravo Bleach", warehouse: "Warehouse Bravo", unit_cost: "37.00",
                                  quantity: 2)
      expect(response.body).to include("143.00") # aggregate material cost still includes B
      expect(response.body).to include(t_cost("material_details.withheld"))
    end

    it "shows a view_inventory_reports-only user no stock-issue details or links" do
      sign_in user_with("view_laundry_cost_reports", "view_inventory_reports")
      get_report

      expect_line_hidden(issue_a, product: "Alpha Soap", warehouse: "Warehouse Alpha", unit_cost: "23.00", quantity: 3)
      expect_line_hidden(issue_b, product: "Bravo Bleach", warehouse: "Warehouse Bravo", unit_cost: "37.00",
                                  quantity: 2)
      expect(response.body).not_to include("Zeta Laundry Hub")
      expect(response.body).to include("143.00", t_cost("material_details.withheld"))
    end

    it "shows a user without any inventory permission no stock-issue details or links" do
      sign_in user_with("view_laundry_cost_reports")
      get_report

      expect_line_hidden(issue_a, product: "Alpha Soap", warehouse: "Warehouse Alpha", unit_cost: "23.00", quantity: 3)
      expect_line_hidden(issue_b, product: "Bravo Bleach", warehouse: "Warehouse Bravo", unit_cost: "37.00",
                                  quantity: 2)
      expect(response.body).not_to include("Zeta Laundry Hub")
      expect(response.body).to include("143.00", t_cost("material_details.withheld"))
    end

    it "shows a warehouse-A manage_inventory user only A's details" do
      # manage_inventory requires view_inventory (PermissionRole dependency), so
      # this is the supported way to hold it.
      sign_in user_with("view_laundry_cost_reports", "view_inventory", "manage_inventory", warehouses: [ wh_a ])
      get_report

      expect(response.body).to include(issue_a.issue_number, inventory_stock_issue_path(issue_a), "Alpha Soap",
                                       "Warehouse Alpha")
      expect(response.body).to match(%r{<td[^>]*>3</td>})
      expect_line_hidden(issue_b, product: "Bravo Bleach", warehouse: "Warehouse Bravo", unit_cost: "37.00",
                                  quantity: 2)
      expect(response.body).to include("143.00", t_cost("material_details.withheld"))
    end

    it "lets manage_inventory alone (a role saved without its view_inventory dependency) reach A's details only" do
      # Validation refuses this combination; written past it to prove the
      # manage_inventory branch of StockIssuePolicy#index? is what grants access.
      viewer = user_with("view_laundry_cost_reports", warehouses: [ wh_a ])
      viewer.permission_role.update_column(:permissions, %w[view_laundry_cost_reports manage_inventory])
      expect(viewer.reload.can?(:view_inventory)).to be(false)
      sign_in viewer
      get_report

      expect(response.body).to include(issue_a.issue_number, "Alpha Soap", "Warehouse Alpha")
      expect_line_hidden(issue_b, product: "Bravo Bleach", warehouse: "Warehouse Bravo", unit_cost: "37.00",
                                  quantity: 2)
    end

    it "shows an unrestricted view_inventory user every line and no withheld notice" do
      sign_in user_with("view_laundry_cost_reports", "view_inventory")
      get_report

      expect(response.body).to include(issue_a.issue_number, issue_b.issue_number, "Alpha Soap", "Bravo Bleach")
      expect(response.body).not_to include(t_cost("material_details.withheld"))
    end

    it "shows the owner every line and no withheld notice" do
      sign_in owner
      get_report

      expect(response.body).to include(issue_a.issue_number, issue_b.issue_number)
      expect(response.body).not_to include(t_cost("material_details.withheld"))
    end

    it "shows the empty message, not the withheld notice, when there are no lines at all" do
      sign_in user_with("view_laundry_cost_reports")
      get laundry_reports_cost_summary_path(from: (from - 3.months).iso8601, to: (from - 2.months).iso8601)

      expect(response.body).to include(CGI.escapeHTML(t_cost("material_details.empty")))
      expect(response.body).not_to include(t_cost("material_details.withheld"))
    end
  end

  describe "laundry branch count" do
    it "blocks the report with a message and no figures when two active laundry branches exist" do
      create(:branch, business: business, branch_type: "laundry", name: "Second Laundry")
      sign_in owner
      get_report

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(CGI.escapeHTML(t_cost("multiple_laundry_branches")))
      (payroll_figures + %w[150.00 411.00 143.00]).each { |figure| expect(response.body).not_to include(figure) }
      expect(response.body).not_to include(issue_a.issue_number, issue_b.issue_number)
      expect(response.body).not_to include(laundry_reports_cost_summary_path(format: :csv))
    end

    it "redirects a CSV request to the HTML report with an alert when two active laundry branches exist" do
      create(:branch, business: business, branch_type: "laundry", name: "Second Laundry")
      sign_in owner
      get_report(format: :csv)

      expect(response).to redirect_to(laundry_reports_cost_summary_path(from: from, to: to))
      expect(flash[:alert]).to eq(t_cost("multiple_laundry_branches"))
      (csv_payroll_figures + %w[150 411 143]).each { |figure| expect(response.body).not_to include(figure) }
    end

    %w[en ar].each do |locale|
      it "renders the multiple-branch message without missing translations in #{locale}" do
        create(:branch, business: business, branch_type: "laundry", name: "Second Laundry")
        owner.update!(preferred_locale: locale)
        sign_in owner
        get_report

        expect(response.body).not_to include("Translation missing")
        expect(response.body).to include(
          CGI.escapeHTML(I18n.t("laundry.reports.cost_summary.multiple_laundry_branches", locale: locale))
        )
      end
    end

    it "reports normally when the second laundry branch is inactive" do
      create(:branch, :inactive, business: business, branch_type: "laundry", name: "Old Laundry")
      sign_in owner
      get_report

      expect(response.body).not_to include(CGI.escapeHTML(t_cost("multiple_laundry_branches")))
      payroll_figures.each { |figure| expect(response.body).to include(figure) }
    end

    it "keeps the existing empty state when no active laundry branch exists" do
      laundry_branch.update_column(:active, false)
      sign_in owner
      get_report

      expect(response.body).to include(CGI.escapeHTML(t_cost("no_laundry_branch")))
      expect(response.body).not_to include(CGI.escapeHTML(t_cost("multiple_laundry_branches")))
    end

    it "is not affected by another business's laundry branch" do
      create(:branch, business: create(:business), branch_type: "laundry")
      sign_in owner
      get_report

      expect(response.body).not_to include(CGI.escapeHTML(t_cost("multiple_laundry_branches")))
      payroll_figures.each { |figure| expect(response.body).to include(figure) }
    end
  end
end
