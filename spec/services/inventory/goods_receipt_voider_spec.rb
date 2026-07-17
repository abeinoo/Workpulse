require "rails_helper"

RSpec.describe Inventory::GoodsReceiptVoider, type: :model do
  let(:business)  { create(:business) }
  let(:actor)     { create(:user, :super_admin, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product) do
    business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0)
  end
  let(:account) { create(:custody_account, business: business) }

  def top_up!(amount)
    account.custody_transactions.create!(business: business, txn_type: "top_up", amount: amount)
    account.refresh_balance!
  end

  def confirmed_receipt(qty: 10, cost: 50, funding_source_kind: "employee_custody", funding_source: account)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current,
                                      funding_source_kind: funding_source_kind, funding_source: funding_source)
    r.items.build(product: product, quantity: qty, unit_cost: cost)
    r.save!
    Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: r.id, actor: actor).call
    r.reload
  end

  def void(receipt, reason: "wrong supplier")
    described_class.new(goods_receipt_id: receipt.id, actor: actor, reason: reason).call
  end

  it "reverses stock, restores the custody balance, and reverses the settlement — all via new entries, never touching the originals" do
    top_up!(1000)
    receipt = confirmed_receipt(qty: 10, cost: 50)
    expect(account.reload.current_balance).to eq(500)
    expect(receipt).to be_settled

    result = void(receipt)

    expect(result.ok?).to be(true)
    expect(receipt.reload).to be_voided
    expect(product.reload.current_stock).to eq(0)
    expect(account.reload.current_balance).to eq(1000)

    original  = receipt.custody_transactions.of_type("inventory_purchase").first
    reversal  = receipt.custody_transactions.of_type("inventory_purchase_reversal").first
    expect(original.amount).to eq(-500) # untouched
    expect(reversal.amount).to eq(500)

    settlements = receipt.financial_settlements.chronological.to_a
    expect(settlements.map(&:amount)).to eq([ 500, -500 ]) # original untouched, reversal appended
    expect(receipt.total_settled_amount).to eq(0)
    expect(receipt).to be_pending_settlement # financial state fully unwound, independent of inventory status
  end

  it "does not touch custody or settlements for a supplier-credit receipt" do
    receipt = confirmed_receipt(funding_source_kind: "supplier_credit", funding_source: nil)

    result = void(receipt)

    expect(result.ok?).to be(true)
    expect(receipt.reload).to be_voided
    expect(CustodyTransaction.where(business: business).count).to eq(0)
    expect(receipt.financial_settlements.count).to eq(0)
  end

  it "rolls back the stock reversal if reversing goods have already been issued out" do
    top_up!(1000)
    receipt = confirmed_receipt(qty: 10, cost: 50)
    branch = business.branches.create!(name: "Branch", active: true)
    issue = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current)
    issue.items.build(product: product, quantity: 8)
    Inventory::StockIssuePoster.new(issue).call

    result = void(receipt)

    expect(result.ok?).to be(false)
    expect(receipt.reload).not_to be_voided
    expect(account.reload.current_balance).to eq(500) # unchanged
  end
end
