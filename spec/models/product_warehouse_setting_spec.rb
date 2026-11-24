require "rails_helper"

RSpec.describe ProductWarehouseSetting, type: :model do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "P", sku: "P-1", initial_cost_price: 1, average_cost_price: 1) }

  it "is valid with a warehouse and non-negative thresholds" do
    setting = product.product_warehouse_settings.build(warehouse: warehouse, low_stock_level: 5, reorder_quantity: 10)
    expect(setting).to be_valid
  end

  it "forbids two settings for the same product+warehouse" do
    product.product_warehouse_settings.create!(warehouse: warehouse, low_stock_level: 5, reorder_quantity: 10)
    dup = product.product_warehouse_settings.build(warehouse: warehouse, low_stock_level: 1, reorder_quantity: 1)
    expect(dup).not_to be_valid
    expect(dup.errors[:warehouse_id]).to be_present
  end

  it "rejects negative thresholds" do
    setting = product.product_warehouse_settings.build(warehouse: warehouse, low_stock_level: -1, reorder_quantity: 0)
    expect(setting).not_to be_valid
  end

  it "rejects a warehouse from another business" do
    other_wh = create(:business).warehouses.create!(name: "Other")
    setting = product.product_warehouse_settings.build(warehouse: other_wh, low_stock_level: 1, reorder_quantity: 1)
    expect(setting).not_to be_valid
    expect(setting.errors[:warehouse_id]).to be_present
  end

  describe "no product-level fallback" do
    it "Product has no stock-setting attributes or fallback helpers of its own" do
      %i[low_stock_level reorder_quantity reorder_level receive_low_stock_notification
         low_stock_level_for reorder_quantity_for low_stock_in? low_stock? setting_for].each do |name|
        expect(product).not_to respond_to(name)
      end
      expect(Product.column_names & RetiredProductStockColumns::COLUMNS).to be_empty
      expect(Product).not_to respond_to(:low_stock)
      expect(Product).not_to respond_to(:low_stock_notifiable)
    end

    it "each warehouse keeps its own values for the same product" do
      other_wh = business.warehouses.create!(name: "Second")
      product.product_warehouse_settings.create!(warehouse: warehouse, low_stock_level: 9, reorder_quantity: 12)
      product.product_warehouse_settings.create!(warehouse: other_wh, low_stock_level: 2, reorder_quantity: 30)
      expect(product.reload.product_warehouse_settings.to_h { |s| [ s.warehouse_id, [ s.low_stock_level, s.reorder_quantity ] ] })
        .to eq(warehouse.id => [ 9, 12 ], other_wh.id => [ 2, 30 ])
    end
  end
end
