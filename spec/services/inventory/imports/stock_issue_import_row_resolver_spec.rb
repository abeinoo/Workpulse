require "rails_helper"

RSpec.describe Inventory::Imports::StockIssueImportRowResolver do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:branch)    { business.branches.create!(name: "Main Branch", active: true) }
  let(:stock_issue) do
    business.stock_issues.create!(warehouse: warehouse, branch: branch, issued_on: Date.current, status: :draft)
  end
  let(:batch) do
    StockIssueImportBatch.create!(business: business, warehouse: warehouse, branch: branch, stock_issue: stock_issue)
  end
  let(:product) do
    business.products.create!(name: "Widget", sku: "W-001", initial_cost_price: 10, average_cost_price: 10)
  end

  def receive(qty)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: product, quantity: qty, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  it "resolves an unknown_sku row when given a product_id with enough stock, appending an item to the draft issue" do
    receive(10)
    row = batch.rows.create!(row_number: 1, sku: "MISSING", quantity: 3, failure_reason: :unknown_sku)

    result = described_class.new(business, row.id, product_id: product.id).call

    expect(result.ok?).to be true
    expect(result.row.status).to eq("resolved")
    expect(result.row.product).to eq(product)
    expect(result.row.stock_issue_item).to be_present
    expect(stock_issue.items.reload.sole.quantity).to eq(3)
  end

  it "keeps the row pending when the selected product still lacks stock, and attaches no item" do
    receive(1)
    row = batch.rows.create!(row_number: 1, sku: "MISSING", quantity: 3, failure_reason: :unknown_sku)

    result = described_class.new(business, row.id, product_id: product.id).call

    expect(result.ok?).to be false
    expect(result.row.status).to eq("pending")
    expect(result.row.failure_reason).to eq("insufficient_stock")
    expect(result.row.available_hint).to eq(1)
    expect(stock_issue.items.reload).to be_empty
  end

  it "resolves an invalid_row when given a valid sku" do
    row = batch.rows.create!(row_number: 1, sku: "", quantity: 3, failure_reason: :invalid_row)
    receive(10)

    result = described_class.new(business, row.id, sku: product.sku).call

    expect(result.ok?).to be true
    expect(result.row.product).to eq(product)
    expect(stock_issue.items.reload.sole.product).to eq(product)
  end

  it "resolves an insufficient_stock row when the quantity is lowered to the available amount" do
    receive(4)
    row = batch.rows.create!(
      row_number: 1, sku: product.sku, quantity: 5, product: product,
      failure_reason: :insufficient_stock, available_hint: 4
    )

    result = described_class.new(business, row.id, quantity: 4).call

    expect(result.ok?).to be true
    expect(result.row.quantity).to eq(4)
    expect(stock_issue.items.reload.sole.quantity).to eq(4)
  end

  it "updates the same item in place on a second resolve instead of adding a duplicate" do
    receive(10)
    row = batch.rows.create!(row_number: 1, sku: product.sku, quantity: 3, failure_reason: :invalid_row)

    described_class.new(business, row.id, sku: product.sku).call
    first_item_id = row.reload.stock_issue_item_id

    described_class.new(business, row.id, quantity: 5).call

    expect(row.reload.stock_issue_item_id).to eq(first_item_id)
    expect(stock_issue.items.reload.sole.quantity).to eq(5)
  end

  it "skips a row regardless of its failure reason" do
    row = batch.rows.create!(row_number: 1, sku: "X", quantity: 1, failure_reason: :invalid_row)

    result = described_class.new(business, row.id, skip: true).call

    expect(result.ok?).to be true
    expect(result.row.status).to eq("skipped")
  end

  it "detaches the item when a resolved row is skipped" do
    receive(10)
    row = batch.rows.create!(row_number: 1, sku: product.sku, quantity: 3, failure_reason: :invalid_row)
    described_class.new(business, row.id, sku: product.sku).call
    expect(stock_issue.items.reload).not_to be_empty

    described_class.new(business, row.id, skip: true).call

    expect(row.reload.stock_issue_item_id).to be_nil
    expect(stock_issue.items.reload).to be_empty
  end
end
