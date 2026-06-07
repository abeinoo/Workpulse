require "rails_helper"

RSpec.describe "Inventory::StockCounts", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }

  let(:counter) do  # can create/edit drafts but NOT post
    role = business.permission_roles.create!(name: "Counter", permissions: %w[view_inventory manage_stock_counts])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end
  let(:poster) do   # can post
    role = business.permission_roles.create!(name: "Poster", permissions: %w[view_inventory post_stock_counts])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let!(:warehouse) { business.warehouses.create!(name: "Main") }
  let!(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
  end

  before do
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: product, quantity: 20, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  def create_draft(counted: 17, as:)
    sign_in as
    post inventory_stock_counts_path, params: {
      stock_count: { warehouse_id: warehouse.id, counted_on: Date.current,
                     items_attributes: { "0" => { product_id: product.id, counted_quantity: counted } } }
    }
    business.stock_counts.order(:id).last
  end

  describe "draft lifecycle" do
    it "renders index and new" do
      sign_in owner
      get inventory_stock_counts_path
      expect(response).to have_http_status(:ok)
      get new_inventory_stock_count_path
      expect(response).to have_http_status(:ok)
    end

    it "creates a draft and snapshots the system quantity + variance" do
      count = create_draft(counted: 17, as: counter)
      expect(count).to be_draft
      item = count.items.first
      expect(item.system_quantity).to eq(20)
      expect(item.difference).to eq(-3)
    end
  end

  describe "posting (segregation of duties)" do
    it "lets a poster post the count and corrects stock" do
      count = create_draft(counted: 17, as: counter)
      sign_in poster
      patch post_inventory_stock_count_path(count)
      expect(response).to redirect_to(inventory_stock_count_path(count))
      expect(count.reload).to be_posted
      expect(product.reload.current_stock).to eq(17)
      expect(count.stock_adjustment).to be_present
    end

    it "forbids a counter (no post permission) from posting" do
      count = create_draft(counted: 17, as: counter)
      sign_in counter
      patch post_inventory_stock_count_path(count)
      expect(response).to redirect_to(root_path)
      expect(count.reload).to be_draft
    end

    it "forbids editing a posted count" do
      count = create_draft(counted: 17, as: counter)
      sign_in owner
      patch post_inventory_stock_count_path(count)

      patch inventory_stock_count_path(count), params: { stock_count: { notes: "tamper" } }
      expect(count.reload.notes).to be_blank
    end
  end
end
