require "rails_helper"

RSpec.describe Inventory::AdjustmentPoster, type: :model do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 0, average_cost_price: 0)
  end

  def adjust(reason:, lines:)
    a = business.stock_adjustments.build(warehouse: warehouse, adjusted_on: Date.current, reason: reason)
    lines.each { |l| a.items.build(product: product, **l) }
    described_class.new(a).call
  end

  it "auto-numbers adjustments per business" do
    result = adjust(reason: "stock_count", lines: [ { quantity_difference: 5 } ])
    expect(result.adjustment.adjustment_number).to match(/\AADJ-\d{6}\z/)
  end

  describe "opening balance (cost-bearing)" do
    it "increases stock and establishes the average cost" do
      result = adjust(reason: "opening_balance", lines: [ { quantity_difference: 50, unit_cost: 90 } ])
      expect(result.ok?).to be(true)
      expect(product.reload.current_stock).to eq(50)
      expect(product.average_cost_price).to eq(90)
      mv = result.adjustment.inventory_movements.first
      expect(mv.reason).to eq("opening_balance")
      expect(mv.direction).to eq("in")
    end
  end

  describe "quantity-only corrections" do
    before { adjust(reason: "opening_balance", lines: [ { quantity_difference: 100, unit_cost: 10 } ]) }

    it "decreases stock for damaged goods without changing the average cost" do
      expect { adjust(reason: "damaged", lines: [ { quantity_difference: -5 } ]) }
        .not_to change { product.reload.average_cost_price }
      expect(product.reload.current_stock).to eq(95)
      mv = product.inventory_movements.where(reason: "adjustment", direction: "out").last
      expect(mv.quantity).to eq(5)
    end

    it "increases stock for a positive count correction without changing the average" do
      adjust(reason: "stock_count", lines: [ { quantity_difference: 3 } ])
      expect(product.reload.current_stock).to eq(103)
      expect(product.average_cost_price).to eq(10)
    end
  end

  describe "guards" do
    it "blocks a negative adjustment larger than the warehouse on hand" do
      adjust(reason: "opening_balance", lines: [ { quantity_difference: 2, unit_cost: 10 } ])
      result = adjust(reason: "lost", lines: [ { quantity_difference: -5 } ])
      expect(result.ok?).to be(false)
      expect(result.adjustment.errors[:base].join).to match(/available/i)
      expect(product.reload.current_stock).to eq(2)
    end

    it "rejects a zero quantity difference" do
      result = adjust(reason: "stock_count", lines: [ { quantity_difference: 0 } ])
      expect(result.ok?).to be(false)
    end
  end

  it "appears in the product's movement history" do
    adjust(reason: "opening_balance", lines: [ { quantity_difference: 10, unit_cost: 5 } ])
    expect(product.inventory_movements.where(reason: "opening_balance").count).to eq(1)
  end
end
