require "rails_helper"

RSpec.describe StockCount, type: :model do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "P", sku: "P-1", initial_cost_price: 1, average_cost_price: 1) }

  def draft(counted: 5)
    c = business.stock_counts.build(warehouse: warehouse, counted_on: Date.current)
    c.items.build(product: product, system_quantity: 3, counted_quantity: counted)
    c
  end

  it "auto-assigns a sequential SC number on create" do
    c = draft
    c.save!
    expect(c.count_number).to match(/\ASC-\d{6}\z/)
  end

  it "defaults to draft and computes item variance (counted − system)" do
    c = draft(counted: 5)
    c.save!
    expect(c).to be_draft
    expect(c.items.first.difference).to eq(2)
  end

  it "requires at least one item" do
    c = business.stock_counts.build(warehouse: warehouse, counted_on: Date.current)
    expect(c).not_to be_valid
  end

  it "forbids the same product twice in one count" do
    c = business.stock_counts.build(warehouse: warehouse, counted_on: Date.current)
    c.items.build(product: product, counted_quantity: 1)
    c.items.build(product: product, counted_quantity: 2)
    expect(c).not_to be_valid
  end

  describe "uncounted rows (blank counted quantity)" do
    let(:other) { business.products.create!(name: "Q", sku: "Q-1", initial_cost_price: 2, average_cost_price: 2) }

    let(:count) do
      c = business.stock_counts.build(warehouse: warehouse, counted_on: Date.current)
      c.items.build(product: product, system_quantity: 3, counted_quantity: 1)  # counted
      c.items.build(product: other,   system_quantity: 4)                       # uncounted (nil)
      c.save!
      c
    end

    it "leaves difference nil and treats the row as not counted" do
      uncounted = count.items.find_by(product: other)
      expect(uncounted.counted?).to be(false)
      expect(uncounted.difference).to be_nil
    end

    it "rejects a fractional counted quantity (whole units only)" do
      item = count.items.find_by(product: product)
      item.counted_quantity = 2.5
      expect(item).not_to be_valid
      expect(item.errors[:counted_quantity]).to be_present
    end

    it "reports progress over counted rows only" do
      expect(count.total_products).to eq(2)
      expect(count.counted_products).to eq(1)
      expect(count.remaining_products).to eq(1)
      expect(count.completion_percentage).to eq(50)
      expect(count.fully_counted?).to be(false)
    end

    it "excludes uncounted rows from variance figures" do
      expect(count.matched_count).to eq(0)
      expect(count.shortage_count).to eq(1)   # product: 1 − 3 = −2
      expect(count.overage_count).to eq(0)
    end
  end

  describe "immutability after approval" do
    let(:approved) do
      c = draft
      c.save!
      c.update_columns(status: "approved", approved_at: Time.current)
      c
    end

    it "blocks updates once approved" do
      approved.notes = "tamper"
      expect(approved.save).to be(false)
      expect(approved.errors[:base]).to be_present
    end

    it "raises on destroy once past draft" do
      expect { approved.destroy }.to raise_error(ImmutableDocument::DeletionNotAllowedError)
    end

    it "still allows editing and deleting a draft" do
      c = draft
      c.save!
      expect(c.update(notes: "ok")).to be(true)
      expect { c.destroy }.not_to raise_error
    end
  end
end
