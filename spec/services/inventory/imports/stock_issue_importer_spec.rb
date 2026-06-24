require "rails_helper"

RSpec.describe Inventory::Imports::StockIssueImporter do
  let(:business)   { create(:business) }
  let(:warehouse)  { business.warehouses.create!(name: "Main") }
  let(:branch)     { business.branches.create!(name: "Main Branch", active: true) }

  def csv_for(sku, qty = 5)
    "SKU,Quantity\n#{sku},#{qty}\n"
  end

  def importer(csv_data)
    described_class.new(business, csv_data, warehouse: warehouse, branch: branch)
  end

  def receive(product, qty:)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: product, quantity: qty, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  describe "archived product exclusion" do
    it "skips an archived product and records :unknown_sku reason" do
      product = business.products.create!(
        name: "Archived Widget", sku: "AW-001",
        initial_cost_price: 10, average_cost_price: 10
      )
      receive(product, qty: 20)
      product.update!(active: false, archived_at: Time.current)

      result = importer(csv_for(product.sku, 3)).call

      expect(result.issue).to be_nil
      expect(result.skipped_count).to eq(1)
      expect(result.skipped.first.reason).to eq(:unknown_sku)
      expect(result.skipped.first.sku).to eq(product.sku)
    end

    it "creates an issue only for active products when the CSV mixes active and archived" do
      active_product = business.products.create!(
        name: "Active Widget", sku: "ACT-001",
        initial_cost_price: 10, average_cost_price: 10
      )
      archived_product = business.products.create!(
        name: "Archived Widget", sku: "ARC-001",
        initial_cost_price: 10, average_cost_price: 10
      )
      receive(active_product,   qty: 20)
      receive(archived_product, qty: 20)
      archived_product.update!(active: false, archived_at: Time.current)

      csv = "SKU,Quantity\n#{active_product.sku},3\n#{archived_product.sku},2\n"
      result = importer(csv).call

      expect(result.issue).to be_present
      expect(result.issued_count).to eq(1)
      expect(result.issue.items.map(&:product)).to contain_exactly(active_product)
      expect(result.skipped_count).to eq(1)
      expect(result.skipped.first.sku).to eq(archived_product.sku)
    end
  end

  describe "valid import" do
    it "creates a stock issue for an active product with sufficient stock" do
      product = business.products.create!(
        name: "Widget", sku: "W-001",
        initial_cost_price: 10, average_cost_price: 10
      )
      receive(product, qty: 20)

      result = importer(csv_for(product.sku, 5)).call

      expect(result.ok?).to be true
      expect(result.issue).to be_present
      expect(result.issued_count).to eq(1)
    end
  end
end
