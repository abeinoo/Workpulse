require "rails_helper"

RSpec.describe PurchaseRequestItem, type: :model do
  let(:business)  { create(:business) }
  let(:supplier)  { business.suppliers.create!(name: "Acme") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Widget", sku: "W-1", average_cost_price: 100) }
  let(:actor)     { create(:user, :super_admin, business: business) }

  def build_pr(quantity: 10)
    pr = business.purchase_requests.build(supplier: supplier, source: "low_stock_alert")
    pr.items.build(product: product, quantity: quantity, unit_price: 100)
    pr.save!
    pr.update_column(:status, "approved")
    pr.reload
  end

  def confirmed_receipt(pri, quantity:)
    receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current,
                                            purchase_request: pri.purchase_request)
    receipt.items.build(product: pri.product, quantity: quantity, unit_cost: 100, purchase_request_item: pri)
    receipt.save!
    receipt.update_column(:approval_status, "approved")
    result = Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: receipt.id, actor: actor).call
    raise "confirmation failed: #{result.error}" unless result.ok?

    receipt.reload
  end

  def draft_receipt(pri, quantity:)
    receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current,
                                            purchase_request: pri.purchase_request)
    receipt.items.build(product: pri.product, quantity: quantity, unit_cost: 100, purchase_request_item: pri)
    receipt.save!
    receipt
  end

  describe "#remaining_quantity" do
    it "equals the full requested quantity before anything is received" do
      pr = build_pr(quantity: 10)
      expect(pr.items.sole.remaining_quantity).to eq(10)
      expect(pr.items.sole.received_quantity).to eq(0)
    end

    it "decreases only after a receipt is CONFIRMED, not while it's a draft" do
      pr  = build_pr(quantity: 10)
      pri = pr.items.sole
      draft_receipt(pri, quantity: 6)

      expect(pri.reload.received_quantity).to eq(0)
      expect(pri.remaining_quantity).to eq(10)
    end

    it "decreases after confirmation and supports multiple partial receipts" do
      pr  = build_pr(quantity: 10)
      pri = pr.items.sole

      confirmed_receipt(pri, quantity: 6)
      expect(pri.reload.remaining_quantity).to eq(4)

      confirmed_receipt(pri, quantity: 4)
      expect(pri.reload.remaining_quantity).to eq(0)
      expect(pri.received_quantity).to eq(10)
    end

    it "never goes negative even if somehow over-received historically" do
      pr  = build_pr(quantity: 10)
      pri = pr.items.sole
      confirmed_receipt(pri, quantity: 10)
      pri.reload

      # Simulate a historical anomaly directly, bypassing the guard, to prove
      # the calculation itself is defensive.
      allow(pri).to receive(:received_quantity).and_return(15)
      expect(pri.remaining_quantity).to eq(0)
    end
  end

  describe "PurchaseRequest#sync_receiving_status!" do
    it "moves approved -> partially_received -> fully_received as receipts confirm" do
      pr  = build_pr(quantity: 10)
      pri = pr.items.sole

      confirmed_receipt(pri, quantity: 6)
      expect(pr.reload).to be_partially_received

      confirmed_receipt(pri, quantity: 4)
      expect(pr.reload).to be_fully_received
    end

    it "tracks multiple products with independently different received quantities" do
      product_b = business.products.create!(name: "Gadget", sku: "G-1", average_cost_price: 50)
      pr = business.purchase_requests.build(supplier: supplier, source: "low_stock_alert")
      pr.items.build(product: product, quantity: 10, unit_price: 100)
      pr.items.build(product: product_b, quantity: 5, unit_price: 50)
      pr.save!
      pr.update_column(:status, "approved")
      pr.reload

      item_a = pr.items.find_by(product: product)
      item_b = pr.items.find_by(product: product_b)

      confirmed_receipt(item_a, quantity: 10) # fully receives product A only
      expect(pr.reload).to be_partially_received
      expect(item_a.reload.remaining_quantity).to eq(0)
      expect(item_b.reload.remaining_quantity).to eq(5)

      confirmed_receipt(item_b, quantity: 5)
      expect(pr.reload).to be_fully_received
    end
  end
end
