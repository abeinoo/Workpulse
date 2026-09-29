require "rails_helper"

RSpec.describe Inventory::Imports::StockIssueImportBatchCompleter do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:branch)    { business.branches.create!(name: "Main Branch", active: true) }
  let(:user)      { create(:user, business: business) }
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

  # A resolved row always owns the item it appended to the draft issue — mirrors
  # what StockIssueImportRowResolver does, so the completer sees the same shape.
  def resolve_row(quantity:)
    item = stock_issue.items.create!(product: product, quantity: quantity)
    batch.rows.create!(row_number: 1, sku: product.sku, quantity: quantity,
                       product: product, status: :resolved, stock_issue_item: item)
  end

  it "refuses to complete while rows are still pending" do
    receive(10)
    batch.rows.create!(row_number: 1, sku: product.sku, quantity: 3, failure_reason: :unknown_sku)

    result = described_class.new(business, batch.id, user: user).call

    expect(result.ok?).to be false
    expect(batch.reload).to be_draft
  end

  it "submits the batch's draft issue for approval and marks the batch completed — without deducting stock" do
    receive(10)
    row = resolve_row(quantity: 3)

    result = nil
    expect { result = described_class.new(business, batch.id, user: user).call }
      .not_to change(InventoryMovement, :count)

    expect(result.ok?).to be true
    expect(batch.reload).to be_completed
    expect(row.reload.status).to eq("imported")
    expect(stock_issue.reload).to be_pending_approval
    expect(stock_issue.submitted_by).to eq(user)
    expect(stock_issue.items.sum(:quantity)).to eq(3)
    expect(product.stock_in(warehouse)).to eq(10)
  end

  it "is a no-op on a batch that was already completed (double click / refresh)" do
    receive(10)
    resolve_row(quantity: 3)
    described_class.new(business, batch.id, user: user).call

    result = described_class.new(business, batch.id, user: user).call

    expect(result.ok?).to be true
    expect(stock_issue.reload).to be_pending_approval
    expect(AuditLog.for_auditable(stock_issue).where(action: "submit_for_approval").count).to eq(1)
  end

  it "completes a batch with no resolved rows (everything skipped) without posting the issue" do
    batch.rows.create!(row_number: 1, sku: "X", quantity: 1, status: :skipped)

    result = described_class.new(business, batch.id, user: user).call

    expect(result.ok?).to be true
    expect(batch.reload).to be_completed
    expect(stock_issue.reload).to be_draft
  end

  it "reopens the offending row (detaching its item) and keeps the batch draft if stock ran out in the meantime" do
    receive(2)
    row = resolve_row(quantity: 3)

    result = described_class.new(business, batch.id, user: user).call

    expect(result.ok?).to be false
    expect(batch.reload).to be_draft
    expect(stock_issue.reload).to be_draft
    expect(row.reload.status).to eq("pending")
    expect(row.failure_reason).to eq("insufficient_stock")
    expect(row.available_hint).to eq(2)
    expect(row.stock_issue_item_id).to be_nil
    expect(stock_issue.items.reload).to be_empty
  end

  it "leaves other resolved rows attached when only one product runs short" do
    ok_product = business.products.create!(name: "OK", sku: "OK-1", initial_cost_price: 5, average_cost_price: 5)
    ok_receipt = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    ok_receipt.items.build(product: ok_product, quantity: 20, unit_cost: 5)
    Inventory::GoodsReceiptPoster.new(ok_receipt).call

    receive(2)
    short_row = resolve_row(quantity: 3)
    ok_item = stock_issue.items.create!(product: ok_product, quantity: 5)
    ok_row = batch.rows.create!(row_number: 2, sku: ok_product.sku, quantity: 5,
                                product: ok_product, status: :resolved, stock_issue_item: ok_item)

    result = described_class.new(business, batch.id, user: user).call

    expect(result.ok?).to be false
    expect(short_row.reload.status).to eq("pending")
    expect(ok_row.reload.status).to eq("resolved")
    expect(ok_row.stock_issue_item_id).to eq(ok_item.id)
  end
end
