require "rails_helper"

RSpec.describe ProductWarehouseSetting, type: :model do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "P", sku: "P-1", initial_cost_price: 1, average_cost_price: 1, low_stock_level: 2, reorder_quantity: 4) }

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

  describe "Product helpers" do
    it "falls back to the product default when no override exists" do
      expect(product.low_stock_level_for(warehouse)).to eq(2)
      expect(product.reorder_quantity_for(warehouse)).to eq(4)
    end

    it "uses the warehouse override when present" do
      product.product_warehouse_settings.create!(warehouse: warehouse, low_stock_level: 9, reorder_quantity: 12)
      product.reload
      expect(product.low_stock_level_for(warehouse)).to eq(9)
      expect(product.reorder_quantity_for(warehouse)).to eq(12)
    end
  end
end
