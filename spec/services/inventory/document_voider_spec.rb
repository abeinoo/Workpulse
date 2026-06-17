require "rails_helper"

RSpec.describe Inventory::DocumentVoider, type: :model do
  let(:business) { create(:business) }
  let(:user)     { create(:user, :super_admin, business: business) }
  let(:main)     { business.warehouses.create!(name: "Main") }
  let(:branch)   { business.warehouses.create!(name: "Branch") }
  let(:product) do
    business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0)
  end

  def receipt(qty:, cost:, wh: main)
    r = business.goods_receipts.build(warehouse: wh, received_on: Date.current)
    r.items.build(product: product, quantity: qty, unit_cost: cost)
    Inventory::GoodsReceiptPoster.new(r).call.receipt
  end

  def issue(qty:, wh: main)
    branch = business.branches.first_or_create!(name: "Void Branch", active: true)
    i = business.stock_issues.build(warehouse: wh, branch: branch, issued_on: Date.current)
    i.items.build(product: product, quantity: qty)
    Inventory::StockIssuePoster.new(i).call.issue
  end

  def void(doc, reason: "correction")
    described_class.new(doc, user: user, reason: reason).call
  end

  describe "goods receipt void" do
    it "reverses stock and recomputes the moving-average cost correctly" do
      r1 = receipt(qty: 10, cost: 100)
      receipt(qty: 10, cost: 120)                  # avg now 110, stock 20
      expect(product.reload.average_cost_price).to eq(110)

      result = void(r1)                            # remove the 10@100 receipt
      expect(result.ok?).to be(true)
      expect(product.reload.current_stock).to eq(10)
      expect(product.average_cost_price).to eq(120) # only the 10@120 remains
    end

    it "keeps the original document and movements untouched, adding a reversal" do
      r = receipt(qty: 5, cost: 50)
      expect { void(r) }.to change { r.inventory_movements.count }.from(1).to(2)
      original = r.inventory_movements.find_by(reason: "goods_receipt")
      reversal = r.inventory_movements.find_by(reason: "reversal")
      expect(original.direction).to eq("in")
      expect(reversal.direction).to eq("out")
      expect(reversal.quantity).to eq(5)
    end

    it "records who/when/why" do
      r = receipt(qty: 5, cost: 50)
      void(r, reason: "duplicate invoice")
      r.reload
      expect(r).to be_voided
      expect(r.voided_by).to eq(user)
      expect(r.voided_at).to be_present
      expect(r.void_reason).to eq("duplicate invoice")
    end

    it "refuses to void if the received goods have already been issued out" do
      r = receipt(qty: 10, cost: 100)
      issue(qty: 8)                                # only 2 left in Main
      result = void(r)
      expect(result.ok?).to be(false)
      expect(r.errors[:base].join).to match(/only .* on hand/i)
      expect(r.reload).not_to be_voided
      expect(product.reload.current_stock).to eq(2) # unchanged
    end

    it "refuses to void twice" do
      r = receipt(qty: 5, cost: 50)
      void(r)
      result = void(r.reload)
      expect(result.ok?).to be(false)
      expect(r.errors[:base].join).to match(/already been voided/i)
    end

    it "requires a reason" do
      r = receipt(qty: 5, cost: 50)
      result = described_class.new(r, user: user, reason: "  ").call
      expect(result.ok?).to be(false)
      expect(r).not_to be_voided
    end
  end

  describe "stock issue void" do
    it "restores stock to the original warehouse with a reversal IN" do
      receipt(qty: 10, cost: 100)
      i = issue(qty: 4)
      expect(product.reload.current_stock).to eq(6)

      expect(void(i).ok?).to be(true)
      expect(product.reload.current_stock).to eq(10)
      expect(i.inventory_movements.where(reason: "reversal", direction: "in").count).to eq(1)
      expect(i.reload).to be_voided
    end
  end

  describe "stock transfer void" do
    it "returns the quantity to the source warehouse" do
      receipt(qty: 10, cost: 100, wh: main)
      t = business.stock_transfers.build(source_warehouse: main, destination_warehouse: branch, transferred_on: Date.current)
      t.items.build(product: product, quantity: 6)
      Inventory::StockTransferPoster.new(t).call
      expect(product.stock_in(main)).to eq(4)
      expect(product.stock_in(branch)).to eq(6)

      expect(void(t).ok?).to be(true)
      expect(product.stock_in(main)).to eq(10)
      expect(product.stock_in(branch)).to eq(0)
      expect(t.reload).to be_voided
    end

    it "refuses if the transferred goods have left the destination" do
      receipt(qty: 10, cost: 100, wh: main)
      t = business.stock_transfers.build(source_warehouse: main, destination_warehouse: branch, transferred_on: Date.current)
      t.items.build(product: product, quantity: 6)
      Inventory::StockTransferPoster.new(t).call
      issue(qty: 5, wh: branch)                    # only 1 left in branch

      result = void(t)
      expect(result.ok?).to be(false)
      expect(product.stock_in(branch)).to eq(1)    # unchanged
    end
  end

  describe "warehouse balance integrity" do
    it "leaves every warehouse balance equal to the live ledger after a void" do
      receipt(qty: 10, cost: 100, wh: main)
      r2 = receipt(qty: 5, cost: 100, wh: branch)
      void(r2)
      # Live ledger == helper-derived stock for each warehouse
      [ main, branch ].each do |wh|
        ledger = product.inventory_movements.where(warehouse: wh)
                        .sum { |m| m.direction_in? ? m.quantity : -m.quantity }
        expect(product.stock_in(wh)).to eq(ledger)
      end
      expect(product.stock_in(branch)).to eq(0)
    end
  end
end
