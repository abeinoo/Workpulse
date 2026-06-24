require "rails_helper"

RSpec.describe Inventory::Imports::StockCountImporter do
  let(:business)       { create(:business) }
  let(:warehouse)      { business.warehouses.create!(name: "Main") }
  let(:seed_product)   {
    business.products.create!(name: "Seed", sku: "SEED-001",
                              initial_cost_price: 1, average_cost_price: 1)
  }
  let(:count) {
    c = business.stock_counts.build(warehouse: warehouse, counted_on: Date.current)
    c.items.build(product: seed_product, counted_quantity: 0)
    c.save!
    c
  }

  def csv_for(sku, qty = 5)
    "SKU,Counted Quantity\n#{sku},#{qty}\n"
  end

  def importer(csv_data)
    described_class.new(count, csv_data)
  end

  describe "archived product exclusion" do
    it "skips an archived product and records :unknown_sku reason" do
      product = business.products.create!(
        name: "Archived Widget", sku: "AW-001",
        initial_cost_price: 10, average_cost_price: 10, active: false, archived_at: Time.current
      )

      result = importer(csv_for(product.sku)).call

      expect(result.applied_count).to eq(0)
      expect(result.skipped_count).to eq(1)
      expect(result.skipped.first.reason).to eq(:unknown_sku)
      expect(result.skipped.first.sku).to eq(product.sku)
    end

    it "applies an active product on the same run while skipping the archived one" do
      active_product = business.products.create!(
        name: "Active Widget", sku: "ACT-001",
        initial_cost_price: 10, average_cost_price: 10
      )
      archived_product = business.products.create!(
        name: "Archived Widget", sku: "ARC-001",
        initial_cost_price: 10, average_cost_price: 10,
        active: false, archived_at: Time.current
      )

      csv = "SKU,Counted Quantity\n#{active_product.sku},3\n#{archived_product.sku},7\n"
      result = importer(csv).call

      expect(result.applied_count).to eq(1)
      expect(result.skipped_count).to eq(1)
      expect(result.skipped.first.sku).to eq(archived_product.sku)
    end
  end

  describe "valid import" do
    it "applies rows for active products" do
      product = business.products.create!(
        name: "Widget", sku: "W-001",
        initial_cost_price: 10, average_cost_price: 10
      )

      result = importer(csv_for(product.sku, 12)).call

      expect(result.ok?).to be true
      expect(result.applied_count).to eq(1)
      expect(count.items.find_by(product: product).counted_quantity).to eq(12)
    end
  end
end
