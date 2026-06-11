require "rails_helper"

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
