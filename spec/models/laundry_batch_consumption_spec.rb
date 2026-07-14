require "rails_helper"

RSpec.describe LaundryBatchConsumption, type: :model do
  let(:business) { create(:business) }
  let(:laundry_branch) { create(:branch, business: business, branch_type: "laundry") }
  let(:warehouse) { business.warehouses.create!(name: "Laundry Warehouse") }
  let(:product) do
    business.products.create!(name: "Detergent", sku: "DET-1", unit_of_measure: "kg",
                              initial_cost_price: 20, average_cost_price: 20)
  end
  let(:movement) do
    InventoryMovement.create!(business: business, product: product, warehouse: warehouse, direction: :out,
                              reason: :laundry_consumption, quantity: 1, unit_cost: 20, occurred_on: Date.current)
  end
  let(:towel_type) { business.towel_types.create!(name: "Bath Towel") }
  let(:batch) do
    business.laundry_batches.create!(laundry_branch: laundry_branch, towel_type: towel_type, batch_number: "LB-000001")
  end

  it "is invalid with neither a laundry_batch nor a laundry_branch" do
    consumption = described_class.new(product: product, inventory_movement: movement, quantity: 1,
                                       unit_cost_snapshot: 20, total_cost_snapshot: 20)
    expect(consumption).not_to be_valid
  end

  it "is valid with a laundry_branch only (standalone workflow)" do
    consumption = described_class.new(laundry_branch: laundry_branch, product: product, inventory_movement: movement,
                                       quantity: 1, unit_cost_snapshot: 20, total_cost_snapshot: 20)
    expect(consumption).to be_valid
  end

  it "is valid with a laundry_batch only (legacy/advanced workflow)" do
    consumption = described_class.new(laundry_batch: batch, product: product, inventory_movement: movement,
                                       quantity: 1, unit_cost_snapshot: 20, total_cost_snapshot: 20)
    expect(consumption).to be_valid
  end

  it "is invalid with BOTH a laundry_batch and a laundry_branch" do
    consumption = described_class.new(laundry_batch: batch, laundry_branch: laundry_branch, product: product,
                                       inventory_movement: movement, quantity: 1, unit_cost_snapshot: 20,
                                       total_cost_snapshot: 20)
    expect(consumption).not_to be_valid
  end

  describe "#branch" do
    it "resolves through the batch when batch-tied" do
      consumption = described_class.create!(laundry_batch: batch, product: product, inventory_movement: movement,
                                            quantity: 1, unit_cost_snapshot: 20, total_cost_snapshot: 20)
      expect(consumption.branch).to eq(laundry_branch)
    end

    it "resolves directly when standalone" do
      consumption = described_class.create!(laundry_branch: laundry_branch, product: product,
                                            inventory_movement: movement, quantity: 1, unit_cost_snapshot: 20,
                                            total_cost_snapshot: 20)
      expect(consumption.branch).to eq(laundry_branch)
    end
  end
end
