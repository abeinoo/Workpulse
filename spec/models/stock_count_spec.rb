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

  describe "immutability after posting" do
    let(:posted) do
      c = draft
      c.save!
      c.update_columns(status: "posted", posted_at: Time.current)
      c
    end

    it "blocks updates once posted" do
      posted.notes = "tamper"
      expect(posted.save).to be(false)
      expect(posted.errors[:base]).to be_present
    end

    it "raises on destroy once posted" do
      expect { posted.destroy }.to raise_error(ImmutableDocument::DeletionNotAllowedError)
    end

    it "still allows editing and deleting a draft" do
      c = draft
      c.save!
      expect(c.update(notes: "ok")).to be(true)
      expect { c.destroy }.not_to raise_error
    end
  end
end
