require "rails_helper"

RSpec.describe Laundry::BatchMaterialConsumer, type: :model do
  let(:business) { create(:business) }
  let(:laundry_branch) { create(:branch, business: business, branch_type: "laundry") }
  let(:laundry_warehouse) { business.warehouses.create!(name: "Laundry Warehouse") }
  let(:towel_type) { business.towel_types.create!(name: "Bath Towel") }
  let(:product) do
    business.products.create!(name: "Detergent", sku: "DET-1", unit_of_measure: "kg",
                              initial_cost_price: 20, average_cost_price: 20)
  end
  let(:actor) { create(:user, business: business) }

  let(:batch) do
    Laundry::LaundryBatchService.create(actor: actor, laundry_branch_id: laundry_branch.id,
                                        towel_type_id: towel_type.id).batch
  end

  before do
    receipt = business.goods_receipts.build(warehouse: laundry_warehouse, received_on: Date.current)
    receipt.items.build(product: product, quantity: 100, unit_cost: 20)
    Inventory::GoodsReceiptPoster.new(receipt).call
  end

  it "decreases the laundry warehouse's balance and links a LaundryBatchConsumption to the movement" do
    result = described_class.new(batch, laundry_warehouse).call(product: product, quantity: 3)

    expect(result.ok?).to be(true)
    expect(product.stock_in(laundry_warehouse)).to eq(97)
    expect(result.consumption.total_cost_snapshot).to eq(60)
    expect(result.consumption.inventory_movement.reason).to eq("laundry_consumption")
  end

  it "freezes the cost snapshot even if the product's average cost changes afterward" do
    result = described_class.new(batch, laundry_warehouse).call(product: product, quantity: 3)

    product.update!(average_cost_price: 999)

    expect(result.consumption.reload.unit_cost_snapshot).to eq(20)
  end

  it "rejects consumption beyond the laundry warehouse's on-hand balance" do
    result = described_class.new(batch, laundry_warehouse).call(product: product, quantity: 1000)

    expect(result.ok?).to be(false)
    expect(product.stock_in(laundry_warehouse)).to eq(100)
  end
end
