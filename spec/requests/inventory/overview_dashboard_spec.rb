require "rails_helper"

RSpec.describe "Inventory overview dashboard", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }
  let!(:main)    { business.warehouses.create!(name: "Main Warehouse") }
  let(:branch)   { business.branches.create!(name: "Nasr Branch", active: true) }
  let(:supplier) { business.suppliers.create!(name: "Acme") }
  let(:low)      { business.products.create!(name: "LowItem", sku: "LOW-1", initial_cost_price: 10, average_cost_price: 10, reorder_level: 5, reorder_quantity: 12) }
  let(:empty)    { business.products.create!(name: "EmptyItem", sku: "EMP-1", initial_cost_price: 3, average_cost_price: 3) }
  let(:today)    { BusinessDay.current(context: business) }

  def receive(product, qty, wh: main)
    r = business.goods_receipts.build(warehouse: wh, received_on: today)
    r.items.build(product: product, quantity: qty, unit_cost: product.average_cost_price)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  def issue(product, qty, wh: main)
    i = business.stock_issues.build(warehouse: wh, branch: branch, issued_on: today)
    i.items.build(product: product, quantity: qty)
    approve_and_post_stock_issue(i)
  end

  def body_text = Nokogiri::HTML(response.body).text.squish

  def action_titles
    Nokogiri::HTML(response.body).css("#action-center .inv-dash__action-title").map { |n| n.text.squish }
  end

  describe "with data" do
    before do
      receive(low, 6)
      issue(low, 2)   # 4 left → low stock (reorder level 5)
      empty           # tracked, never received → out of stock
      # pending documents
      business.goods_receipts.build(warehouse: main, supplier: supplier, received_on: today, approval_status: "pending_approval")
              .tap { |r| r.items.build(product: low, quantity: 1, unit_cost: 10) }.save!
      business.stock_issues.build(warehouse: main, branch: branch, issued_on: today, status: "pending_approval")
              .tap { |i| i.items.build(product: low, quantity: 1) }.save!
      business.purchase_requests.build(supplier: supplier, status: "pending_approval")
              .tap { |pr| pr.items.build(product: low, quantity: 5, unit_price: 10) }.save!
      counter = create(:user, :super_admin, business: business)
      count = business.stock_counts.build(warehouse: main, counted_on: today, created_by: counter)
      count.items.build(product: low, counted_quantity: 4)
      count.save!
      count.start_counting!(counter)
      count.mark_completed!(counter)
      sign_in owner
    end

    it "shows the KPI row with real counts, each linking to the filtered page" do
      get inventory_root_path
      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      kpis = doc.css(".inv-dash__kpis .kpi-card").to_h { |c| [ c.at_css(".kpi-card__label").text.squish, [ c.at_css(".kpi-card__value").text.squish, c["href"] ] ] }
      ov = ->(k) { I18n.t("inventory.dashboard.overview.kpis.#{k}") }
      expect(kpis[ov.(:stock_value)].first).to include("40")                                    # 4 × 10
      expect(kpis[ov.(:products)].first).to eq("2")
      # LowStockQuery also counts EmptyItem (0 on hand ≤ reorder level 0) — existing low-stock rule.
      expect(kpis[ov.(:low_stock)]).to eq([ Inventory::LowStockQuery.new(business).alerts.size.to_s, inventory_low_stock_report_path ])
      expect(kpis[ov.(:out_of_stock)]).to eq([ "1", inventory_current_stock_report_path(stock_status: "out_of_stock") ])
      expect(kpis[ov.(:open_purchase_requests)]).to eq([ "1", inventory_purchase_requests_path(needs_action: "1") ])
      expect(kpis[ov.(:pending_receipts)]).to eq([ "1", inventory_goods_receipts_path(approval_status: "pending_approval") ])
      expect(kpis[ov.(:pending_issues)]).to eq([ "1", inventory_stock_issues_path(workflow_status: "pending_approval") ])
      expect(kpis[ov.(:pending_counts)]).to eq([ "1", inventory_stock_counts_path(status: "completed") ])
    end

    it "the Action Center lists only categories with work, with count and action" do
      get inventory_root_path
      titles = action_titles
      a = ->(k) { I18n.t("inventory.dashboard.overview.actions.#{k}.title") }
      expect(titles).to include("#{a.(:out_of_stock)} — 1", "#{a.(:low_stock)} — 2", "#{a.(:purchase_requests)} — 1",
                                "#{a.(:receipts_pending_approval)} — 1", "#{a.(:issues_pending_approval)} — 1",
                                "#{a.(:counts_awaiting_approval)} — 1")
      expect(titles.join).not_to include(a.(:counts_in_progress))
      expect(response.body).not_to include(I18n.t("inventory.dashboard.overview.all_good"))
    end

    it "movement overview, purchase recommendations, active products and recent movements" do
      get inventory_root_path
      text = body_text
      expect(text).to include(I18n.t("inventory.dashboard.overview.movements_title"), I18n.t("inventory.dashboard.overview.needs_purchase"))
      expect(response.body).to include('id="low-stock-alerts"', 'data-amount="120.0"') # 12 × 10 suggested
      doc = Nokogiri::HTML(response.body)
      active = doc.at_css("#active-products tbody tr").text.squish
      expect(active).to include("LowItem", "2", "Nasr Branch")
      expect(response.body).to include(business.stock_issues.find_by(status: "issued").issue_number)
      expect(response.body.scan('data-chart-type-value="line"').size).to eq(1)
    end

    it "the period selector changes the movement window" do
      get inventory_root_path, params: { period: "today" }
      expect(Nokogiri::HTML(response.body).at_css("#movement-overview .exec-card__toggle .is-active").text.squish)
        .to eq(I18n.t("inventory.dashboard.overview.periods.today"))
      get inventory_root_path, params: { period: "custom", from: (today - 400).iso8601, to: (today - 300).iso8601 }
      expect(body_text).to include(I18n.t("inventory.dashboard.overview.no_movements"))
    end

    it "product search shows quick actions for the chosen product" do
      get inventory_root_path, params: { product_id: low.id }
      quick = Nokogiri::HTML(response.body).at_css(".inv-dash__quick")
      expect(quick.text).to include("LowItem", I18n.t("inventory.dashboard.overview.quick.product_movements"))
      expect(quick.to_html).to include(inventory_movements_report_path(product_id: low.id), new_inventory_stock_issue_path)
    end
  end

  it "shows the trend chart when the period has flows on more than one day" do
    receive(low, 6)
    InventoryMovement.last.update_columns(occurred_on: today - 3)
    issue(low, 1)
    sign_in owner
    get inventory_root_path, params: { period: "7d" }
    expect(response.body).to include('data-chart-type-value="line"')
  end

  it "caps purchase recommendations at the most urgent rows and links to the full Low Stock report" do
    12.times { |i| business.products.create!(name: "Item#{i}", sku: "IT-#{i}", initial_cost_price: 1, average_cost_price: 1, reorder_level: 5, reorder_quantity: 5) }
    sign_in owner
    get inventory_root_path
    section = Nokogiri::HTML(response.body).at_css("#low-stock-alerts")
    expect(section.css("tbody tr").size).to eq(Inventory::DashboardController::PURCHASE_ROWS)
    expect(section.at_css(".badge").text.squish).to eq("12")
    expect(response.body).to include(I18n.t("inventory.dashboard.overview.view_all_low_stock", count: 12))
  end

  it "empty business: all-clear state and no crashes" do
    sign_in owner
    get inventory_root_path
    expect(response).to have_http_status(:ok)
    expect(body_text).to include(I18n.t("inventory.dashboard.overview.all_good"), I18n.t("inventory.dashboard.overview.no_movements"))
  end

  describe "warehouses" do
    before do
      north = business.warehouses.create!(name: "North Warehouse")
      receive(low, 6)
      receive(low, 3, wh: north)
      sign_in owner
    end

    it "shows the warehouse summary table when there are several warehouses" do
      get inventory_root_path
      expect(body_text).to include(I18n.t("inventory.dashboard.overview.warehouse_summary"), "Main Warehouse", "North Warehouse")
    end

    it "a warehouse-scoped user only sees their warehouse's numbers and gets the compact summary" do
      role = business.permission_roles.create!(name: "Scoped", permissions: %w[view_inventory])
      scoped = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id); u.assigned_warehouses << main }
      sign_in scoped
      get inventory_root_path
      text = body_text
      expect(text).not_to include(I18n.t("inventory.dashboard.overview.warehouse_summary"))
      expect(response.body).to include("inv-dash__single-warehouse")
      expect(text).not_to include("North Warehouse")
      value = Nokogiri::HTML(response.body).css(".kpi-card").first.at_css(".kpi-card__value").text
      expect(value).to include("60") # 6 × 10 in Main only
    end
  end

  describe "permissions" do
    it "a view-only user sees no create actions and no KPIs for documents they can't list" do
      role = business.permission_roles.create!(name: "ReportsOnly", permissions: %w[view_inventory_reports])
      viewer = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
      sign_in viewer
      get inventory_root_path
      expect(response).to have_http_status(:ok)
      text = body_text
      expect(text).not_to include(I18n.t("inventory.goods_receipts.new_action"), I18n.t("inventory.dashboard.overview.quick.transfer"))
      expect(text).not_to include(I18n.t("inventory.dashboard.overview.kpis.pending_receipts"))
    end

    it "users without inventory access are redirected" do
      sign_in create(:user, business: business)
      get inventory_root_path
      expect(response).to redirect_to(root_path)
    end
  end

  it "renders RTL in Arabic with card tables for mobile and the theme-aware chart component" do
    owner.update!(preferred_locale: "ar")
    receive(low, 6)
    InventoryMovement.last.update_columns(occurred_on: today - 2)
    issue(low, 1)
    sign_in owner
    get inventory_root_path, params: { period: "7d" }
    expect(response.body).to match(/<html[^>]*dir="rtl"/)
    expect(response.body).to include("يحتاج إلى إجراء", "ملخص حركة المخزون", "أكثر المنتجات حركة")
    expect(response.body).not_to include("translation missing")
    expect(response.body.scan("table-wrap table-wrap--cards").size).to be >= 3
    expect(response.body).to include('data-controller="chart"') # palette follows light/dark theme tokens
  end
end
