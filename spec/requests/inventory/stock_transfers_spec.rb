require "rails_helper"

RSpec.describe "Inventory::StockTransfers", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }

  let(:transfer_only) do
    role = business.permission_roles.create!(name: "Transfers",
                                             permissions: %w[view_inventory manage_stock_transfers])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:viewer) do
    role = business.permission_roles.create!(name: "Viewer", permissions: %w[view_inventory])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let!(:source) { business.warehouses.create!(name: "Main") }
  let!(:dest)   { business.warehouses.create!(name: "Branch") }
  let!(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
  end

  before do
    r = business.goods_receipts.build(warehouse: source, received_on: Date.current)
    r.items.build(product: product, quantity: 10, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  def transfer_params(qty)
    { stock_transfer: {
      source_warehouse_id: source.id, destination_warehouse_id: dest.id,
      transferred_on: Date.current,
      items_attributes: { "0" => { product_id: product.id, quantity: qty } }
    } }
  end

  describe "GET pages" do
    before { sign_in owner }

    it "renders index and new" do
      get inventory_stock_transfers_path
      expect(response).to have_http_status(:ok)
      get new_inventory_stock_transfer_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST create" do
    it "posts a transfer and moves stock between warehouses" do
      sign_in transfer_only
      post inventory_stock_transfers_path, params: transfer_params(4)
      expect(business.stock_transfers.count).to eq(1)
      expect(product.stock_in(source)).to eq(6)
      expect(product.stock_in(dest)).to eq(4)
    end

    it "rejects an over-transfer (422, nothing moved)" do
      sign_in owner
      post inventory_stock_transfers_path, params: transfer_params(99)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(business.stock_transfers.count).to eq(0)
      expect(product.stock_in(source)).to eq(10)
    end
  end

  describe "access control" do
    it "denies a view-only user from creating a transfer" do
      sign_in viewer
      post inventory_stock_transfers_path, params: transfer_params(1)
      expect(response).to redirect_to(root_path)
      expect(business.stock_transfers.count).to eq(0)
    end
  end
end
