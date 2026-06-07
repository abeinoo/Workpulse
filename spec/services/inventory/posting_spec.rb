require "rails_helper"

RSpec.describe "Inventory posting & costing", type: :model do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:warehouse_b) { business.warehouses.create!(name: "Branch") }
  let(:supplier)  { business.suppliers.create!(name: "Acme") }
  let(:product) do
    business.products.create!(name: "Hair Color", sku: "HC-1",
                              initial_cost_price: 0, average_cost_price: 0)
  end

  def post_receipt(qty:, cost:, wh: warehouse)
    receipt = business.goods_receipts.build(warehouse: wh, supplier: supplier, received_on: Date.current)
    receipt.items.build(product: product, quantity: qty, unit_cost: cost)
    Inventory::GoodsReceiptPoster.new(receipt).call
  end

  def post_issue(qty:, wh: warehouse)
    issue = business.stock_issues.build(warehouse: wh, issued_on: Date.current)
    issue.items.build(product: product, quantity: qty)
    Inventory::StockIssuePoster.new(issue).call
  end

  describe "stock derived from the movement ledger" do
    it "increases on receipt and decreases on issue" do
      post_receipt(qty: 10, cost: 100)
      expect(product.reload.current_stock).to eq(10)
      post_issue(qty: 4)
      expect(product.reload.current_stock).to eq(6)
    end
  end

  describe "moving weighted-average cost (spec example)" do
    it "averages 10@100 then 10@120 to 110, last cost 120" do
      post_receipt(qty: 10, cost: 100)
      post_receipt(qty: 10, cost: 120)
      product.reload
      expect(product.average_cost_price).to eq(110)
      expect(product.last_purchase_price).to eq(120)
    end

    it "values an issue at the current average cost" do
      post_receipt(qty: 10, cost: 100)
      post_receipt(qty: 10, cost: 120)
      result = post_issue(qty: 5)
      expect(result.ok?).to be(true)
      expect(result.issue.items.first.unit_cost).to eq(110)
      expect(result.issue.items.first.total_cost).to eq(550)
    end
  end

  describe "over-issue protection" do
    it "blocks issuing more than the warehouse on-hand and records no movement" do
      post_receipt(qty: 5, cost: 100)
      result = post_issue(qty: 6)
      expect(result.ok?).to be(false)
      expect(result.issue.errors[:base].join).to match(/available/i)
      expect(product.reload.current_stock).to eq(5)
    end
  end

  describe "per-warehouse isolation" do
    it "tracks on-hand independently per warehouse" do
      post_receipt(qty: 10, cost: 100, wh: warehouse)
      post_receipt(qty: 3,  cost: 100, wh: warehouse_b)
      expect(product.stock_in(warehouse)).to eq(10)
      expect(product.stock_in(warehouse_b)).to eq(3)
      expect(product.current_stock).to eq(13)
    end

    it "cannot satisfy an issue from a different warehouse's stock" do
      post_receipt(qty: 10, cost: 100, wh: warehouse)
      result = post_issue(qty: 1, wh: warehouse_b)
      expect(result.ok?).to be(false)
    end
  end

  describe "auto-numbering" do
    it "assigns sequential, prefixed, per-business numbers" do
      r1 = post_receipt(qty: 1, cost: 1)
      r2 = post_receipt(qty: 1, cost: 1)
      expect(r1.receipt.receipt_number).to match(/\AGRN-\d{6}\z/)
      expect(r2.receipt.receipt_number).not_to eq(r1.receipt.receipt_number)

      post_receipt(qty: 5, cost: 1)
      i1 = post_issue(qty: 1)
      expect(i1.issue.issue_number).to match(/\AISS-\d{6}\z/)
    end
  end

  describe "low-stock detection" do
    it "flags a product at or below its low-stock level" do
      product.update!(low_stock_level: 5)
      post_receipt(qty: 5, cost: 100)
      expect(product.reload.low_stock?).to be(true)
      post_receipt(qty: 1, cost: 100)
      expect(product.reload.low_stock?).to be(false)
    end
  end
end
