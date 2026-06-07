require "rails_helper"

RSpec.describe "Inventory voids & adjustments", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }
  let(:viewer) do
    role = business.permission_roles.create!(name: "Viewer", permissions: %w[view_inventory])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end
  let!(:warehouse) { business.warehouses.create!(name: "Main") }
  let!(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 0, average_cost_price: 0)
  end

  def post_receipt(qty: 10, cost: 10)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: product, quantity: qty, unit_cost: cost)
    Inventory::GoodsReceiptPoster.new(r).call.receipt
  end

  describe "stock adjustment pages & creation" do
    before { sign_in owner }

    it "renders index and new" do
      get inventory_stock_adjustments_path
      expect(response).to have_http_status(:ok)
      get new_inventory_stock_adjustment_path
      expect(response).to have_http_status(:ok)
    end

    it "posts an opening-balance adjustment and updates stock + cost" do
      post inventory_stock_adjustments_path, params: {
        stock_adjustment: {
          warehouse_id: warehouse.id, adjusted_on: Date.current, reason: "opening_balance",
          items_attributes: { "0" => { product_id: product.id, quantity_difference: 40, unit_cost: 7 } }
        }
      }
      expect(business.stock_adjustments.count).to eq(1)
      expect(product.reload.current_stock).to eq(40)
      expect(product.average_cost_price).to eq(7)
    end

    it "rejects a damaged adjustment that exceeds stock (422)" do
      post inventory_stock_adjustments_path, params: {
        stock_adjustment: {
          warehouse_id: warehouse.id, adjusted_on: Date.current, reason: "damaged",
          items_attributes: { "0" => { product_id: product.id, quantity_difference: -5 } }
        }
      }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(business.stock_adjustments.count).to eq(0)
    end
  end

  describe "void action" do
    it "voids a receipt through the web with a reason" do
      sign_in owner
      receipt = post_receipt
      patch void_inventory_goods_receipt_path(receipt), params: { void_reason: "wrong supplier" }
      expect(response).to redirect_to(inventory_goods_receipt_path(receipt))
      expect(receipt.reload).to be_voided
      expect(receipt.void_reason).to eq("wrong supplier")
      expect(product.reload.current_stock).to eq(0)
    end

    it "shows Active then Voided status on the show page" do
      sign_in owner
      receipt = post_receipt
      get inventory_goods_receipt_path(receipt)
      expect(response.body).to include(I18n.t("inventory.void.status_active"))

      patch void_inventory_goods_receipt_path(receipt), params: { void_reason: "x" }
      get inventory_goods_receipt_path(receipt)
      expect(response.body).to include(I18n.t("inventory.void.status_voided"))
    end
  end

  describe "access control" do
    it "forbids a view-only user from voiding" do
      sign_in viewer
      receipt = post_receipt
      patch void_inventory_goods_receipt_path(receipt), params: { void_reason: "nope" }
      expect(response).to redirect_to(root_path)
      expect(receipt.reload).not_to be_voided
    end

    it "forbids a view-only user from creating an adjustment" do
      sign_in viewer
      post inventory_stock_adjustments_path, params: {
        stock_adjustment: { warehouse_id: warehouse.id, adjusted_on: Date.current, reason: "stock_count",
                            items_attributes: { "0" => { product_id: product.id, quantity_difference: 1 } } }
      }
      expect(response).to redirect_to(root_path)
      expect(business.stock_adjustments.count).to eq(0)
    end
  end
end
