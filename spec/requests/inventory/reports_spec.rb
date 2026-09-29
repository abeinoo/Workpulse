require "rails_helper"
require "csv"

RSpec.describe "Inventory::Reports", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }
  let(:accountant) do
    role = business.permission_roles.create!(name: "Acct", permissions: %w[view_inventory_reports])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let!(:wh_a) { business.warehouses.create!(name: "Warehouse A") }
  let!(:wh_b) { business.warehouses.create!(name: "Warehouse B") }
  let!(:supplier) { business.suppliers.create!(name: "Acme") }
  let!(:product)  { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10) }

  before do
    [ [ wh_a, 10 ], [ wh_b, 4 ] ].each do |wh, qty|
      r = business.goods_receipts.build(warehouse: wh, supplier: supplier, received_on: Date.current)
      r.items.build(product: product, quantity: qty, unit_cost: 10)
      Inventory::GoodsReceiptPoster.new(r).call
    end
  end

  describe "as owner (all warehouses)" do
    before { sign_in owner }

    it "renders the report landing + all three reports" do
      get inventory_reports_path
      expect(response).to have_http_status(:ok)
      [ inventory_current_stock_report_path, inventory_movements_report_path, inventory_supplier_purchases_report_path ].each do |path|
        get path
        expect(response).to have_http_status(:ok)
      end
    end

    it "current stock totals all warehouses (14 units, value 140)" do
      get inventory_current_stock_report_path
      expect(response.body).to include("140")
    end

    it "supplier purchases sums all receipts (14 × 10 = 140)" do
      get inventory_supplier_purchases_report_path
      expect(response.body).to include("Acme")
      expect(response.body).to include("140")
    end
  end

  describe "movement report reflects the live ledger" do
    before { sign_in owner }

    it "shows a just-posted stock issue first, with the balance after it" do
      branch = business.branches.create!(name: "Nasr City", active: true)
      issue  = business.stock_issues.build(warehouse: wh_a, branch: branch, issued_on: Date.current)
      issue.items.build(product: product, quantity: 3)
      approve_and_post_stock_issue(issue)

      get inventory_movements_report_path, params: { warehouse_id: wh_a.id }
      first_row = response.body[/<tbody>.*?<\/tr>/m]
      expect(first_row).to include(I18n.t("inventory.movements.reasons.stock_issue"))
      expect(first_row).to match(%r{>-3</td>\s*<td[^>]*>7</td>})
    end

    it "a date-filtered window continues from the opening balance, not zero" do
      get inventory_movements_report_path, params: { warehouse_id: wh_a.id, from: Date.tomorrow.iso8601 }
      expect(response.body).to include(I18n.t("inventory.reports.movements.empty"))

      get inventory_movements_report_path, params: { warehouse_id: wh_a.id, from: Date.current.iso8601 }
      expect(response.body).to match(%r{>\+10</td>\s*<td[^>]*>—</td>\s*<td[^>]*>10</td>})
    end
  end

  describe "reports dashboard" do
    let(:all_report_paths) do
      [ inventory_current_stock_report_path, inventory_current_stock_report_path(stock_status: "out_of_stock"),
        inventory_low_stock_report_path, inventory_no_movement_report_path, inventory_movements_report_path,
        inventory_consumption_report_path, inventory_transfers_report_path, inventory_adjustments_report_path,
        inventory_purchases_report_path, inventory_supplier_purchases_report_path ]
    end

    before { sign_in owner }

    it "renders the hub with every group, card and headline figure" do
      get inventory_reports_path
      expect(response).to have_http_status(:ok)
      %w[overview movements purchasing transfers adjustments].each do |group|
        expect(response.body).to include(CGI.escapeHTML(I18n.t("inventory.reports.groups.#{group}")))
      end
      all_report_paths.each { |path| expect(response.body).to include(path.gsub("&", "&amp;")) }
      expect(response.body).to include(I18n.t("inventory.reports.kpis.total_value"))
    end

    it "renders every report with filters applied (no errors, no missing translations)" do
      filters = { from: 1.month.ago.to_date.iso8601, to: Date.current.iso8601, warehouse_id: wh_a.id, product_id: product.id }
      all_report_paths.each do |path|
        get path, params: filters
        expect(response).to have_http_status(:ok), path
        expect(response.body).not_to include("translation missing"), path
      end
    end

    it "movement report shows the document number, in/out columns and filters by type" do
      get inventory_movements_report_path, params: { reason: "goods_receipt", direction: "in" }
      receipt = business.goods_receipts.first
      expect(response.body).to include(receipt.receipt_number)
      get inventory_movements_report_path, params: { reason: "stock_issue" }
      expect(response.body).to include(I18n.t("inventory.reports.movements.empty"))
    end

    it "low stock offers the purchase-request action only with purchasing permission" do
      product.update!(reorder_level: 20, reorder_quantity: 30)
      get inventory_low_stock_report_path
      expect(response.body).to include("Shampoo")
      expect(response.body).to include('data-low-stock-selection-target="createBtn"')

      sign_in accountant
      get inventory_low_stock_report_path
      expect(response.body).to include("Shampoo")
      expect(response.body).not_to include('data-low-stock-selection-target="createBtn"')
    end
  end

  describe "movement report pagination and export" do
    before do
      sign_in owner
      branch = business.branches.create!(name: "Nasr City", active: true)
      12.times do
        i = business.stock_issues.build(warehouse: wh_a, branch: branch, issued_on: Date.current)
        i.items.build(product: product, quantity: 0.5)
        approve_and_post_stock_issue(i)
      end
    end

    it "shows the total, the page size, and pagination links that keep the filters" do
      get inventory_movements_report_path, params: { warehouse_id: wh_a.id, per_page: 25 }
      expect(response.body).to include(I18n.t("inventory.reports.results_count", count: 13))
      expect(response.body).not_to include("pagination__btn--next")

      other = business.warehouses.create!(name: "Unused")
      get inventory_movements_report_path, params: { per_page: 25, warehouse_id: other.id }
      expect(response.body).to include(I18n.t("inventory.reports.results_count", count: 0))
    end

    it "paginates server-side and keeps filters + page size in the links" do
      stub_const("Inventory::Reports::Movements::PER_PAGE_OPTIONS", [ 5, 25, 50, 100 ])
      get inventory_movements_report_path, params: { warehouse_id: wh_a.id, reason: "stock_issue", per_page: 5 }
      expect(response.body.scan(/<tbody>.*?<\/tbody>/m).first.scan("<tr>").size).to eq(5)
      next_link = response.body[/href="([^"]*page=2[^"]*)"/, 1]
      expect(CGI.unescapeHTML(next_link)).to include("warehouse_id=#{wh_a.id}", "reason=stock_issue", "per_page=5")
    end

    it "exports CSV and XLSX with the same filters" do
      get inventory_movements_report_export_path, params: { warehouse_id: wh_a.id, reason: "goods_receipt", file: "csv" }
      expect(response.media_type).to eq("text/csv")
      rows = CSV.parse(response.body.delete_prefix("\uFEFF"))
      expect(rows.size).to eq(2)
      expect(rows.last[4]).to eq("Warehouse A")

      get inventory_movements_report_export_path, params: { reason: "stock_issue", file: "xlsx" }
      expect(response.media_type).to eq(Inventory::Reports::MovementsExport::XLSX_TYPE)
      expect(Roo::Excelx.new(StringIO.new(response.body)).sheet(0).last_row).to eq(13)
    end

    it "a warehouse-scoped user's export excludes other warehouses" do
      manager = create(:user, business: business)
      role = business.permission_roles.create!(name: "WhMgr", permissions: %w[view_inventory view_inventory_reports])
      manager.update_column(:permission_role_id, role.id)
      manager.assigned_warehouses << wh_b
      sign_in manager
      get inventory_movements_report_export_path, params: { file: "csv" }
      rows = CSV.parse(response.body.delete_prefix("\uFEFF"))
      expect(rows.drop(1).map { |r| r[4] }.uniq).to eq([ "Warehouse B" ])
    end
  end

  describe "branch comparison report" do
    let!(:nasr)    { business.branches.create!(name: "Nasr Branch", active: true) }
    let!(:shubra)  { business.branches.create!(name: "Shubra Branch", active: true) }
    let!(:zamalek) { business.branches.create!(name: "Zamalek Branch", active: true) }

    # Warehouse A supplies Nasr + Shubra (shared); Warehouse B supplies Zamalek.
    before do
      [ [ wh_a, nasr, 3 ], [ wh_a, shubra, 1 ], [ wh_b, zamalek, 2 ] ].each do |wh, branch, qty|
        i = business.stock_issues.build(warehouse: wh, branch: branch, issued_on: Date.current)
        i.items.build(product: product, quantity: qty)
        approve_and_post_stock_issue(i)
      end
    end

    let(:filters) { { product_id: product.id } }

    it "asks for a product first" do
      sign_in owner
      get inventory_branch_comparison_report_path
      expect(response.body).to include(I18n.t("inventory.reports.branch_comparison.pick_product"))
      expect(response.body).to include('data-controller="searchable-select"')
    end

    it "renders branches, the shared-warehouse marker, reconciliation and the chart" do
      sign_in owner
      get inventory_branch_comparison_report_path, params: filters
      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).not_to include("translation missing")
      expect(body).to include("Nasr Branch", "Shubra Branch", "Zamalek Branch", "Warehouse A", "Warehouse B")
      expect(body).to include(I18n.t("inventory.reports.branch_comparison.shared_hint"))
      expect(body).to include(I18n.t("inventory.reports.branch_comparison.reconciled"))
      expect(body).not_to include(I18n.t("inventory.reports.branch_comparison.not_reconciled"))
      expect(body.scan('data-chart-single-hue-value="true"').size).to eq(1)
      today = BusinessDay.current(context: business)
      expect(body).to include(%(value="#{(today - 29).iso8601}"), %(value="#{today.iso8601}")) # default 30-day period shown
    end

    it "drills down into a branch's movements with before/after balances" do
      sign_in owner
      get inventory_branch_comparison_report_path, params: filters.merge(drill_branch_id: nasr.id)
      body = response.body[/id="branch-movements".*/m]
      expect(body).to include(I18n.t("inventory.reports.branch_comparison.drill_title", branch: "Nasr Branch"))
      expect(body).to include(business.stock_issues.find_by(branch: nasr).issue_number)
      expect(body).to include(I18n.t("inventory.reports.results_count", count: 1))
    end

    it "exports CSV and XLSX with the current filters" do
      sign_in owner
      get inventory_branch_comparison_report_export_path, params: filters.merge(file: "csv", warehouse_id: wh_b.id)
      expect(response.media_type).to eq("text/csv")
      rows = CSV.parse(response.body.delete_prefix("\uFEFF"))
      expect(rows[3].first).to eq("Zamalek Branch")
      expect(rows.flatten).not_to include("Nasr Branch")

      get inventory_branch_comparison_report_export_path, params: filters.merge(file: "xlsx")
      expect(response.media_type).to eq(Inventory::Reports::BranchComparisonExport::XLSX_TYPE)
      expect(Roo::Excelx.new(StringIO.new(response.body)).sheet(0).last_row).to eq(4)
    end

    it "a warehouse-scoped user sees only their warehouse and the branches it supplies" do
      manager = create(:user, business: business)
      role = business.permission_roles.create!(name: "WhMgr2", permissions: %w[view_inventory view_inventory_reports])
      manager.update_column(:permission_role_id, role.id)
      manager.assigned_warehouses << wh_b
      sign_in manager

      get inventory_branch_comparison_report_path, params: filters
      body = response.body[/<div class="admin-page">.*/m]
      expect(body).to include("Warehouse B", "Zamalek Branch")
      expect(body).not_to include("Warehouse A")
      expect(body).not_to include("Nasr Branch")   # neither in the table nor in the branch filter

      get inventory_branch_comparison_report_path, params: filters.merge(drill_branch_id: nasr.id)
      expect(response.body).not_to include(I18n.t("inventory.reports.branch_comparison.drill_title", branch: "Nasr Branch"))

      get inventory_branch_comparison_report_export_path, params: filters.merge(file: "csv", warehouse_id: wh_a.id)
      expect(CSV.parse(response.body.delete_prefix("\uFEFF")).flatten).not_to include("Nasr Branch", "Warehouse A")
    end

    it "renders right-to-left in Arabic with the mobile card-table layout" do
      owner.update!(preferred_locale: "ar")
      sign_in owner
      get inventory_branch_comparison_report_path, params: filters
      expect(response.body).to match(/<html[^>]*dir="rtl"/)
      expect(response.body).to include("تقرير مقارنة المخزون بين الفروع", "مقارنة الفروع", "مشترك")
      expect(response.body).not_to include("translation missing")
      expect(response.body.scan("table-wrap table-wrap--cards").size).to be >= 2
    end

    it "is listed on the reports hub" do
      sign_in owner
      get inventory_reports_path
      expect(response.body).to include(inventory_branch_comparison_report_path)
    end
  end

  describe "as accountant (reports-only)" do
    before { sign_in accountant }

    it "can view reports" do
      get inventory_current_stock_report_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "warehouse-scoped manager" do
    let(:manager) do
      role = business.permission_roles.create!(name: "Mgr", permissions: %w[view_inventory view_inventory_reports])
      u = create(:user, business: business)
      u.update_column(:permission_role_id, role.id)
      u.assigned_warehouses << wh_a
      u
    end

    it "sees current-stock value for only its warehouse (10 × 10 = 100)" do
      sign_in manager
      get inventory_current_stock_report_path
      expect(response.body).to include("100")
    end

    it "movement report excludes other warehouses' rows" do
      sign_in manager
      get inventory_movements_report_path
      expect(response.body).to include("Warehouse A")
      expect(response.body).not_to include("Warehouse B")
    end
  end
end
