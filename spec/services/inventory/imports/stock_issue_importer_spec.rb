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
    it "holds an archived product in a draft batch with :unknown_sku reason" do
      product = business.products.create!(
        name: "Archived Widget", sku: "AW-001",
        initial_cost_price: 10, average_cost_price: 10
      )
      receive(product, qty: 20)
      product.update!(active: false, archived_at: Time.current)

      result = importer(csv_for(product.sku, 3)).call

      expect(result.issue).to be_nil
      expect(result.batch.rows.count).to eq(1)
      expect(result.batch.rows.first.failure_reason).to eq("unknown_sku")
      expect(result.batch.rows.first.sku).to eq(product.sku)
    end

    it "attaches only the active product's item to the batch's single draft issue" do
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

      expect(result.issue).to be_nil
      expect(result.batch).to be_present
      expect(result.batch.stock_issue).to be_draft
      expect(result.batch.stock_issue.items.map(&:product)).to contain_exactly(active_product)
      expect(result.batch.rows.count).to eq(1)
      expect(result.batch.rows.first.sku).to eq(archived_product.sku)
    end
  end

  describe "valid import" do
    it "creates and posts a stock issue for an active product with sufficient stock" do
      product = business.products.create!(
        name: "Widget", sku: "W-001",
        initial_cost_price: 10, average_cost_price: 10
      )
      receive(product, qty: 20)

      result = importer(csv_for(product.sku, 5)).call

      expect(result.ok?).to be true
      expect(result.issue).to be_present
      expect(result.issue).to be_posted
      expect(result.issue.items.count).to eq(1)
      expect(result.batch).to be_nil
    end
  end

  describe "insufficient stock" do
    it "holds all rows for a product whose combined requested quantity exceeds on-hand stock" do
      product = business.products.create!(
        name: "Widget", sku: "W-002",
        initial_cost_price: 10, average_cost_price: 10
      )
      receive(product, qty: 4)

      result = importer(csv_for(product.sku, 5)).call

      expect(result.issue).to be_nil
      expect(result.batch.rows.count).to eq(1)
      row = result.batch.rows.first
      expect(row.failure_reason).to eq("insufficient_stock")
      expect(row.available_hint).to eq(4)
      expect(row.quantity).to eq(5)
      expect(row.stock_issue_item_id).to be_nil
    end

    it "does not block other products in the same file — the OK product's item lands on the one draft issue" do
      short_product = business.products.create!(
        name: "Short", sku: "S-001", initial_cost_price: 10, average_cost_price: 10
      )
      ok_product = business.products.create!(
        name: "OK", sku: "OK-001", initial_cost_price: 10, average_cost_price: 10
      )
      receive(short_product, qty: 1)
      receive(ok_product,    qty: 20)

      csv = "SKU,Quantity\n#{short_product.sku},5\n#{ok_product.sku},3\n"
      result = importer(csv).call

      expect(result.batch.stock_issue.items.map(&:product)).to contain_exactly(ok_product)
      expect(result.batch.rows.first.sku).to eq(short_product.sku)
    end
  end

  describe "invalid rows" do
    it "holds blank-SKU rows with :invalid_row reason" do
      csv = "SKU,Quantity\n,5\n"
      result = importer(csv).call

      expect(result.issue).to be_nil
      expect(result.batch.rows.first.failure_reason).to eq("invalid_row")
    end
  end

  describe "single-issue lifecycle" do
    it "never creates more than one StockIssue for one import, even when some rows fail" do
      product = business.products.create!(
        name: "Widget", sku: "W-003", initial_cost_price: 10, average_cost_price: 10
      )
      receive(product, qty: 20)

      csv = "SKU,Quantity\n#{product.sku},3\nUNKNOWN,1\n"

      expect { importer(csv).call }.to change(StockIssue, :count).by(1)
    end
  end
end
