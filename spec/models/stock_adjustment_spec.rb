require "rails_helper"

RSpec.describe StockAdjustment, type: :model do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "P", sku: "P-1", initial_cost_price: 1, average_cost_price: 1) }

  def build_adjustment(reason: "manual_correction")
    a = business.stock_adjustments.build(warehouse: warehouse, adjusted_on: Date.current,
                                         reason: reason, adjustment_number: "ADJ-000001")
    a.items.build(product: product, quantity_difference: 5, unit_cost: 1)
    a
  end

  it "is valid with a warehouse, reason, and at least one item" do
    expect(build_adjustment).to be_valid
  end

  it "requires at least one item" do
    a = business.stock_adjustments.build(warehouse: warehouse, adjusted_on: Date.current,
                                         reason: "manual_correction", adjustment_number: "ADJ-1")
    expect(a).not_to be_valid
  end

  it "is immutable — destroy raises" do
    a = build_adjustment
    a.save!
    expect { a.destroy }.to raise_error(ImmutableDocument::DeletionNotAllowedError)
  end

  it "is voidable and exposes reversal entries that undo each line" do
    a = build_adjustment
    a.save!
    entry = a.reversal_entries.first
    expect(entry[:direction]).to eq(:out)   # original +5 → reverse with OUT
    expect(entry[:quantity]).to eq(5)
  end

  it "only treats opening_balance as cost-bearing" do
    expect(build_adjustment(reason: "opening_balance").cost_bearing?).to be(true)
    expect(build_adjustment(reason: "damaged").cost_bearing?).to be(false)
  end

  describe "Voidable scopes" do
    it "separates active from voided" do
      a = build_adjustment
      a.save!
      expect(StockAdjustment.active).to include(a)
      a.update_columns(voided_at: Time.current, void_reason: "x")
      expect(StockAdjustment.voided).to include(a)
      expect(StockAdjustment.active).not_to include(a)
    end
  end

  describe "stock count link (decision D5)" do
    let(:count) do
      c = business.stock_counts.build(warehouse: warehouse, counted_on: Date.current)
      c.items.build(product: product)
      c.save!
      c
    end

    it "requires a stock count for the stock_count reason" do
      a = build_adjustment(reason: "stock_count")
      expect(a).not_to be_valid
      expect(a.errors.details[:reason]).to include(error: :stock_count_requires_count)
    end

    it "requires the stock_count reason when linked to a count" do
      a = build_adjustment
      a.stock_count = count
      expect(a).not_to be_valid
      expect(a.errors.details[:reason]).to include(error: :count_link_requires_stock_count_reason)
    end

    it "requires the count's warehouse and business" do
      a = build_adjustment(reason: "stock_count")
      a.stock_count = count
      expect(a).to be_valid
      a.warehouse = business.warehouses.create!(name: "Annex")
      expect(a).not_to be_valid
      expect(a.errors.details[:warehouse_id]).to include(error: :differs_from_stock_count)
      foreign = create(:business)
      other = foreign.stock_counts.build(warehouse: foreign.warehouses.create!(name: "W"), counted_on: Date.current)
      other.items.build(product: foreign.products.create!(name: "X", sku: "X", initial_cost_price: 1, average_cost_price: 1))
      other.save!
      a.warehouse = warehouse
      a.stock_count = other
      expect(a).not_to be_valid
      expect(a.errors.details[:stock_count_id]).to include(error: :other_business)
    end

    it "keeps historical stock_count adjustments without a count readable and updatable (create-time rule)" do
      legacy = build_adjustment(reason: "stock_count")
      legacy.save!(validate: false)
      expect(legacy.reload.update(voided_at: Time.current, void_reason: "x")).to be(true)
    end
  end
end
