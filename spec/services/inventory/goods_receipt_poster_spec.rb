require "rails_helper"

RSpec.describe Inventory::GoodsReceiptPoster, type: :model do
  let(:business)  { create(:business) }
  let(:actor)     { create(:user, :super_admin, business: business) }
  let(:supplier)  { business.suppliers.create!(name: "Acme") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Widget", sku: "W-1", average_cost_price: 100) }

  def approved_request(quantity: 10)
    pr = business.purchase_requests.build(supplier: supplier, source: "low_stock_alert")
    pr.items.build(product: product, quantity: quantity, unit_price: 100)
    pr.save!
    pr.update_column(:status, "approved")
    pr.reload
  end

  def approved_receipt(pri, quantity:, skip_soft_validation: false)
    receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current,
                                            purchase_request: pri.purchase_request)
    receipt.items.build(product: pri.product, quantity: quantity, unit_cost: 100, purchase_request_item: pri)

    if skip_soft_validation
      # Simulates two racing drafts each independently valid when saved
      # (e.g. saved before the other's confirmation dropped the remaining
      # balance) — bypasses the soft, non-locking model validation so this
      # test can isolate GoodsReceiptPoster's hard, race-safe guard.
      receipt.receipt_number ||= Inventory::NumberSequencer.new(business, :goods_receipt).next_number
      receipt.items.each { |item| item.send(:compute_total_cost) }
      receipt.save!(validate: false)
    else
      receipt.save!
    end

    receipt.update_column(:approval_status, "approved")
    receipt
  end

  it "posts normally when a receipt has no purchase request link (historical behavior unaffected)" do
    receipt = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    receipt.items.build(product: product, quantity: 5, unit_cost: 20)
    receipt.save!

    result = described_class.new(receipt).call

    expect(result.ok?).to be(true)
    expect(product.reload.current_stock).to eq(5)
  end

  it "posts successfully when the quantity is within what remains on the purchase request" do
    pr  = approved_request(quantity: 10)
    pri = pr.items.sole
    receipt = approved_receipt(pri, quantity: 6)

    result = described_class.new(receipt).call

    expect(result.ok?).to be(true)
    expect(product.reload.current_stock).to eq(6)
    expect(pri.reload.received_quantity).to eq(6)
  end

  it "rejects posting when the quantity exceeds what remains, and rolls back the whole receipt" do
    pr  = approved_request(quantity: 10)
    pri = pr.items.sole
    receipt = approved_receipt(pri, quantity: 15, skip_soft_validation: true)

    result = described_class.new(receipt).call

    expect(result.ok?).to be(false)
    expect(product.reload.current_stock).to eq(0)
    expect(receipt.reload.status).to eq("draft")
    expect(InventoryMovement.where(source: receipt).count).to eq(0)
  end

  it "rejects a second receipt once the first has already consumed the remaining balance" do
    pr  = approved_request(quantity: 10)
    pri = pr.items.sole

    first = approved_receipt(pri, quantity: 7)
    expect(described_class.new(first).call.ok?).to be(true)

    second = approved_receipt(pri, quantity: 4, skip_soft_validation: true) # only 3 remain
    result = described_class.new(second).call

    expect(result.ok?).to be(false)
    expect(product.reload.current_stock).to eq(7)
    expect(pri.reload.remaining_quantity).to eq(3)
  end

  it "allows a second receipt that exactly fills the remaining balance (full receiving across two receipts)" do
    pr  = approved_request(quantity: 10)
    pri = pr.items.sole

    first = approved_receipt(pri, quantity: 6)
    described_class.new(first).call

    second = approved_receipt(pri, quantity: 4)
    result = described_class.new(second).call

    expect(result.ok?).to be(true)
    expect(product.reload.current_stock).to eq(10)
    expect(pri.reload.remaining_quantity).to eq(0)
  end

  # Proves the guard is race-safe, not just correct when called sequentially:
  # two receipts for the same remaining balance are posted from separate
  # threads/connections so their transactions can genuinely overlap. The
  # PurchaseRequestItem row lock (see GoodsReceiptPoster#purchase_request_quantities_valid?)
  # must serialize them — total posted quantity must never exceed what was
  # requested, regardless of thread interleaving.
  describe "concurrent posting", :truncation do
    self.use_transactional_tests = false

    after do
      AuditLog.where(business: business).delete_all
      InventoryMovement.where(business: business).delete_all
      GoodsReceiptItem.where(goods_receipt_id: GoodsReceipt.where(business: business).select(:id)).delete_all
      GoodsReceipt.where(business: business).delete_all
      PurchaseRequestItem.where(purchase_request_id: PurchaseRequest.where(business: business).select(:id)).delete_all
      PurchaseRequest.where(business: business).delete_all
      ProductBarcode.where(product_id: Product.where(business: business).select(:id)).delete_all
      Product.where(business: business).delete_all
      Warehouse.where(business: business).delete_all
      Supplier.where(business: business).delete_all
      User.where(business: business).delete_all
      Business.where(id: business.id).delete_all
    end

    it "never lets total confirmed receiving exceed the remaining quantity" do
      pr  = approved_request(quantity: 4)
      pri = pr.items.sole
      # Both draft receipts must exist BEFORE either is confirmed — otherwise
      # the soft, non-locking model validation would already reject the
      # second one from stale-but-still-accurate data, and the test would
      # prove nothing about the Poster's own race-safe guard.
      receipts = [ approved_receipt(pri, quantity: 4), approved_receipt(pri, quantity: 4) ]

      results = []
      mutex   = Mutex.new

      threads = receipts.map do |receipt|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection(prevent_permanent_checkout: true) do
            result = described_class.new(receipt).call
            mutex.synchronize { results << result }
          end
        end
      end
      threads.each(&:join)

      expect(results.count(&:ok?)).to eq(1)
      expect(product.reload.current_stock).to eq(4)
      expect(pri.reload.received_quantity).to eq(4)
    end
  end
end
