require "rails_helper"

RSpec.describe "Inventory per-warehouse thresholds", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }
  let!(:main)    { business.warehouses.create!(name: "Main") }
  let!(:branch)  { business.warehouses.create!(name: "Branch") }

  before { sign_in owner }

  it "saves per-warehouse thresholds from the product form" do
    post inventory_products_path, params: {
      product: {
        name: "Shampoo", sku: "SH-1", initial_cost_price: 5,
        low_stock_level: 0, reorder_quantity: 0,
        product_warehouse_settings_attributes: {
          "0" => { warehouse_id: main.id,   low_stock_level: 5,  reorder_quantity: 20 },
          "1" => { warehouse_id: branch.id, low_stock_level: 10, reorder_quantity: 40 }
        }
      }
    }
    product = business.products.find_by!(sku: "SH-1")
    expect(product.product_warehouse_settings.count).to eq(2)
    expect(product.low_stock_level_for(branch)).to eq(10)
    expect(product.reorder_quantity_for(main)).to eq(20)
  end

  it "shows a zero-stock branch as low on the inventory dashboard" do
    product = business.products.create!(name: "Mask", sku: "MK-1", initial_cost_price: 5, average_cost_price: 5)
    product.product_warehouse_settings.create!(warehouse: branch, low_stock_level: 5, reorder_quantity: 20)
    # Stock the main warehouse heavily; branch stays empty.
    r = business.goods_receipts.build(warehouse: main, received_on: Date.current)
    r.items.build(product: product, quantity: 100, unit_cost: 5)
    Inventory::GoodsReceiptPoster.new(r).call

    get inventory_root_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Branch")
    expect(response.body).to include("Mask")
  end
end
