require "rails_helper"

RSpec.describe Inventory::Imports::StockIssueImporter do
  let(:business)   { create(:business) }
  let(:warehouse)  { business.warehouses.create!(name: "Main") }
  let(:branch)     { business.branches.create!(name: "Main Branch", active: true) }

  def csv_for(sku, qty = 5)
    "SKU,Quantity\n#{sku},#{qty}\n"
  end

  # The importer consumes normalized rows; go through the column mapper's
  # auto-suggestion exactly as the controller does for a standard template.
  def importer(csv_data)
    mapper = Inventory::Imports::CsvColumnMapper.new(csv_data, fields: described_class::COLUMNS)
    described_class.new(business, mapper.rows(mapper.suggested_mapping), warehouse: warehouse, branch: branch)
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
      expect(result.issue).to be_issued
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

  describe "#preview" do
    let!(:product) do
      business.products.create!(name: "Widget", sku: "UYN1", initial_cost_price: 10, average_cost_price: 10)
    end

    before { receive(product, qty: 20) }

    it "reports every row with its spreadsheet row number and exact reason" do
      csv = "SKU,Quantity\nUYN1,2\n,5\nUYN1,abc\nUYN1,0\nUYN1,-3\nNOPE,1\nuyn1,1\n"
      rows = importer(csv).preview

      expect(rows.map { |r| [ r.row_number, r.detail || r.failure_reason ] }).to eq([
        [ 2, nil ],
        [ 3, :missing_sku ],
        [ 4, :invalid_quantity ],
        [ 5, :non_positive_quantity ],
        [ 6, :non_positive_quantity ],
        [ 7, :unknown_sku ],
        [ 8, nil ] # SKU match is case-insensitive
      ])
      expect(rows.select(&:valid?).map(&:product)).to all(eq(product))
    end

    it "flags products whose rows together exceed on-hand stock" do
      rows = importer("SKU,Quantity\nUYN1,15\nUYN1,10\n").preview
      expect(rows.map(&:failure_reason)).to all(eq(:insufficient_stock))
      expect(rows.first.available_hint).to eq(20)
    end

    it "writes nothing" do
      expect { importer("SKU,Quantity\nUYN1,2\nNOPE,1\n").preview }
        .not_to change { [ StockIssue.count, StockIssueImportBatch.count, InventoryMovement.count ] }
    end

    it "persists a batch row's invalid quantity as 0, as before" do
      result = importer("SKU,Quantity\nUYN1,abc\n").call
      expect(result.batch.rows.first).to have_attributes(failure_reason: "invalid_row", quantity: 0)
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
