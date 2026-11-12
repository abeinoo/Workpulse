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
    result = adjust(reason: "manual_correction", lines: [ { quantity_difference: 5 } ])
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

    it "increases stock for a positive manual correction without changing the average" do
      adjust(reason: "manual_correction", lines: [ { quantity_difference: 3 } ])
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
      result = adjust(reason: "manual_correction", lines: [ { quantity_difference: 0 } ])
      expect(result.ok?).to be(false)
    end
  end

  it "appears in the product's movement history" do
    adjust(reason: "opening_balance", lines: [ { quantity_difference: 10, unit_cost: 5 } ])
    expect(product.inventory_movements.where(reason: "opening_balance").count).to eq(1)
  end

  describe "audit and locking" do
    let(:user) { create(:user, :owner, business: business) }

    it "audits the posting with its lines" do
      a = business.stock_adjustments.build(warehouse: warehouse, adjusted_on: Date.current, reason: "opening_balance", created_by: user)
      a.items.build(product: product, quantity_difference: 4, unit_cost: 2)
      described_class.new(a).call
      entry = AuditLog.for_auditable(a).sole
      expect([ entry.action, entry.actor ]).to eq([ "post", user ])
      expect(entry.metadata["lines"]).to eq([ { "product_id" => product.id, "quantity_difference" => "4.0" } ])
    end

    it "locks the products before reading the on-hand, inside the posting transaction" do
      adjust(reason: "opening_balance", lines: [ { quantity_difference: 5, unit_cost: 1 } ])
      order = []
      allow(Inventory::StockAvailability).to receive(:lock_products!).and_wrap_original do |original, ids|
        order << [ :lock, ActiveRecord::Base.connection.transaction_open? ]
        original.call(ids)
      end
      allow_any_instance_of(Product).to receive(:stock_in).and_wrap_original do |original, *args|
        order << :read
        original.call(*args)
      end
      adjust(reason: "damaged", lines: [ { quantity_difference: -1 } ])
      expect(order.first).to eq([ :lock, true ])
      expect(order).to include(:read)
    end
  end

  describe "voiding (DocumentVoider)" do
    let(:user) { create(:user, :owner, business: business) }

    it "audits a manual adjustment void when asked to" do
      result = adjust(reason: "opening_balance", lines: [ { quantity_difference: 5, unit_cost: 1 } ])
      Inventory::DocumentVoider.new(result.adjustment, user: user, reason: "typo", audit: true).call
      entry = AuditLog.for_auditable(result.adjustment).find_by!(action: "void")
      expect(entry.metadata).to include("reason" => "typo")
      expect(entry.metadata["reversal"]).to eq([ { "product_id" => product.id, "warehouse_id" => warehouse.id,
                                                   "direction" => "out", "quantity" => "5.0" } ])
    end
  end
end
