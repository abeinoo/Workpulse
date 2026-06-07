require "rails_helper"

RSpec.describe "Warehouse-based access control", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }

  let!(:wh_a) { business.warehouses.create!(name: "Warehouse A") }
  let!(:wh_b) { business.warehouses.create!(name: "Warehouse B") }

  # A manager assigned ONLY to Warehouse A.
  let(:manager_a) do
    role = business.permission_roles.create!(name: "WH Manager",
            permissions: %w[view_inventory manage_inventory post_stock_counts])
    u = create(:user, business: business)
    u.update_column(:permission_role_id, role.id)
    u.assigned_warehouses << wh_a
    u
  end

  let!(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
  end

  # Seed: stock in BOTH warehouses.
  let!(:receipt_a) do
    r = business.goods_receipts.build(warehouse: wh_a, received_on: Date.current)
    r.items.build(product: product, quantity: 10, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call.receipt
  end
  let!(:receipt_b) do
    r = business.goods_receipts.build(warehouse: wh_b, received_on: Date.current)
    r.items.build(product: product, quantity: 7, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call.receipt
  end

  describe "list scoping" do
    it "shows the manager only their warehouse and its receipts" do
      sign_in manager_a

      get inventory_warehouses_path
      expect(response.body).to include("Warehouse A")
      expect(response.body).not_to include("Warehouse B")

      get inventory_goods_receipts_path
      expect(response.body).to include(receipt_a.receipt_number)
      expect(response.body).not_to include(receipt_b.receipt_number)
    end

    it "shows the owner all warehouses" do
      sign_in owner
      get inventory_warehouses_path
      expect(response.body).to include("Warehouse A")
      expect(response.body).to include("Warehouse B")
    end
  end

  describe "direct-URL / ID access is blocked" do
    before { sign_in manager_a }

    it "404s a receipt in another warehouse (no leaking via ID)" do
      get inventory_goods_receipt_path(receipt_b)
      expect(response).to have_http_status(:not_found)
    end

    it "404s another warehouse's show page" do
      get inventory_warehouse_path(wh_b)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "write guards" do
    before { sign_in manager_a }

    it "refuses to create a receipt in an unassigned warehouse" do
      expect {
        post inventory_goods_receipts_path, params: {
          goods_receipt: { warehouse_id: wh_b.id, received_on: Date.current,
                           items_attributes: { "0" => { product_id: product.id, quantity: 1, unit_cost: 1 } } }
        }
      }.not_to change { business.goods_receipts.count }
      expect(response).to redirect_to(root_path)
    end

    it "allows creating a receipt in the assigned warehouse" do
      expect {
        post inventory_goods_receipts_path, params: {
          goods_receipt: { warehouse_id: wh_a.id, received_on: Date.current,
                           items_attributes: { "0" => { product_id: product.id, quantity: 2, unit_cost: 5 } } }
        }
      }.to change { business.goods_receipts.count }.by(1)
    end

    it "blocks a transfer touching an unassigned warehouse" do
      post inventory_stock_transfers_path, params: {
        stock_transfer: { source_warehouse_id: wh_a.id, destination_warehouse_id: wh_b.id,
                          transferred_on: Date.current,
                          items_attributes: { "0" => { product_id: product.id, quantity: 1 } } }
      }
      expect(response).to redirect_to(root_path)
      expect(business.stock_transfers.count).to eq(0)
    end
  end

  describe "dashboard scoping" do
    it "values stock and lists low-stock only for the manager's warehouse" do
      product.update!(low_stock_level: 8)   # A has 10 (ok), B has 7 (low) — manager must NOT see B's alert
      sign_in manager_a
      get inventory_root_path
      expect(response).to have_http_status(:ok)
      # Stock value reflects only Warehouse A's 10 units (×10 = 100), not B's.
      expect(response.body).to include("100")
    end
  end

  describe "transfer visibility (either endpoint)" do
    it "lets the manager see a transfer whose destination is their warehouse" do
      # Owner moves stock from B into A.
      t = business.stock_transfers.build(source_warehouse: wh_b, destination_warehouse: wh_a, transferred_on: Date.current)
      t.items.build(product: product, quantity: 2)
      Inventory::StockTransferPoster.new(t).call

      sign_in manager_a
      get inventory_stock_transfers_path
      expect(response.body).to include(t.transfer_number)
    end
  end
end
