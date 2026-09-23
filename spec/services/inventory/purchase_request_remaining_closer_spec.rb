require "rails_helper"

RSpec.describe Inventory::PurchaseRequestRemainingCloser, type: :model do
  let(:business)  { create(:business) }
  let(:actor)     { create(:user, :super_admin, business: business) }
  let(:supplier)  { business.suppliers.create!(name: "Acme") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Widget", sku: "W-1", average_cost_price: 100) }

  def request_with(quantity: 10)
    pr = business.purchase_requests.build(supplier: supplier, source: "low_stock_alert")
    pr.items.build(product: product, quantity: quantity, unit_price: 100)
    pr.save!
    pr.update_column(:status, "approved")
    pr.reload
  end

  def confirm_receipt!(pr, quantity:)
    receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current,
                                            purchase_request: pr)
    receipt.items.build(product: product, quantity: quantity, unit_cost: 100, purchase_request_item: pr.items.sole)
    receipt.save!
    receipt.update_column(:approval_status, "approved")
    result = Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: receipt.id, actor: actor).call
    raise "confirmation failed: #{result.error}" unless result.ok?

    receipt
  end

  def close(pr, reason: "No longer needed")
    described_class.new(purchase_request_id: pr.id, actor: actor, reason: reason).call
  end

  # 1. Partially received can close remaining
  it "closes the remaining quantity on a partially received request" do
    pr = request_with(quantity: 10)
    confirm_receipt!(pr, quantity: 6)

    result = close(pr)

    expect(result.ok?).to be(true)
    expect(pr.reload).to be_partially_closed
  end

  # 2. Fully received cannot close remaining
  it "refuses to close a fully received request" do
    pr = request_with(quantity: 10)
    confirm_receipt!(pr, quantity: 10)
    expect(pr.reload).to be_fully_received

    result = close(pr)
    expect(result.ok?).to be(false)
    expect(pr.reload).to be_fully_received
  end

  # 3. Draft cannot close remaining
  it "refuses to close a draft request" do
    pr = business.purchase_requests.build(supplier: supplier, source: "low_stock_alert")
    pr.items.build(product: product, quantity: 10, unit_price: 100)
    pr.save!

    result = close(pr)
    expect(result.ok?).to be(false)
  end

  # 4. Pending approval cannot close remaining
  it "refuses to close a pending_approval request" do
    pr = request_with(quantity: 10)
    pr.update_column(:status, "pending_approval")

    result = close(pr)
    expect(result.ok?).to be(false)
    expect(pr.reload).to be_pending_approval
  end

  # 5. Approved with zero received cannot close remaining
  it "refuses to close an approved request with nothing received yet" do
    pr = request_with(quantity: 10)

    result = close(pr)
    expect(result.ok?).to be(false)
    expect(pr.reload).to be_approved
  end

  # 6. Requires a reason
  it "requires a non-blank reason" do
    pr = request_with(quantity: 10)
    confirm_receipt!(pr, quantity: 6)

    result = close(pr, reason: "  ")
    expect(result.ok?).to be(false)
    expect(pr.reload).to be_partially_received
  end

  # 7. Records user/date/reason
  it "records closed_remaining_by, closed_remaining_at, and close_remaining_reason" do
    pr = request_with(quantity: 10)
    confirm_receipt!(pr, quantity: 6)

    freeze_time do
      close(pr, reason: "Supplier could not provide the quantity")

      pr.reload
      expect(pr.closed_remaining_by).to eq(actor)
      expect(pr.closed_remaining_at).to eq(Time.current)
      expect(pr.close_remaining_reason).to eq("Supplier could not provide the quantity")
    end
  end

  # 8. Creates audit entry
  it "writes an audit log entry with the expected metadata" do
    pr = request_with(quantity: 10)
    confirm_receipt!(pr, quantity: 6)

    close(pr, reason: "No longer needed")

    log = AuditLog.for_auditable(pr).find_by(action: "close_remaining")
    expect(log).to be_present
    expect(log.actor).to eq(actor)
    expect(log.changes_json["status"]).to eq(%w[partially_received partially_closed])
    expect(log.metadata["reason"]).to eq("No longer needed")
    expect(log.metadata["requested_quantity"].to_i).to eq(10)
    expect(log.metadata["received_quantity"].to_i).to eq(6)
    expect(log.metadata["closed_quantity"].to_i).to eq(4)
  end

  # 9. No inventory impact
  it "does not change inventory when closing the remaining quantity" do
    pr = request_with(quantity: 10)
    confirm_receipt!(pr, quantity: 6)
    expect(product.reload.current_stock).to eq(6)

    expect {
      close(pr)
    }.not_to change(InventoryMovement, :count)

    expect(product.reload.current_stock).to eq(6) # +6 only, never +10
  end

  # 10. Does not create a Goods Receipt
  it "does not create a goods receipt" do
    pr = request_with(quantity: 10)
    confirm_receipt!(pr, quantity: 6)

    expect {
      close(pr)
    }.not_to change(GoodsReceipt, :count)
  end

  # 11. Closed remaining quantity cannot be received later
  it "prevents a new goods receipt from being created for the closed remaining quantity" do
    pr = request_with(quantity: 10)
    confirm_receipt!(pr, quantity: 6)
    close(pr)
    pr.reload

    expect(pr.receivable?).to be(false)
    expect(PurchaseRequestPolicy.new(actor, pr).create_goods_receipt?).to be(false)
  end

  # 12 & 13. Status displayed correctly + existing received quantities unchanged
  it "leaves already-received quantities exactly as they were" do
    pr = request_with(quantity: 10)
    confirm_receipt!(pr, quantity: 6)

    close(pr)

    pr.reload
    expect(pr.total_received_quantity).to eq(6)
    expect(pr.items.sole.received_quantity).to eq(6)
  end

  # 14. Remaining quantity calculation remains correct
  it "computes closed_remaining_quantity as requested - received" do
    pr = request_with(quantity: 10)
    confirm_receipt!(pr, quantity: 6)
    close(pr)

    expect(pr.reload.closed_remaining_quantity).to eq(4)
  end

  # 15. Concurrent receiving vs closing is safe
  it "fails safely if the request became fully received while the close was in flight" do
    pr = request_with(quantity: 10)
    confirm_receipt!(pr, quantity: 6)

    closer = described_class.new(purchase_request_id: pr.id, actor: actor, reason: "No longer needed")
    # Simulate a GoodsReceipt for the remaining 4 confirming, and the status
    # flip that sync_receiving_status! performs, in between this closer
    # loading the request and it acquiring the lock. Only trigger the side
    # effect on the first call — the reload inside this very block calls
    # partially_received? again, which must fall through to the real method.
    triggered = false
    allow_any_instance_of(PurchaseRequest).to receive(:partially_received?).and_wrap_original do |method|
      if triggered
        method.call
      else
        triggered = true
        confirm_receipt!(pr, quantity: 4)
        pr.reload.partially_received?
      end
    end

    result = closer.call
    expect(result.ok?).to be(false)
    expect(pr.reload).to be_fully_received
    expect(pr.close_remaining_reason).to be_nil
  end

  it "rejects a supplier/business mismatch by scoping the lookup to the actor's business" do
    other_business = create(:business)
    other_actor = create(:user, :super_admin, business: other_business)
    pr = request_with(quantity: 10)
    confirm_receipt!(pr, quantity: 6)

    expect {
      described_class.new(purchase_request_id: pr.id, actor: other_actor, reason: "x").call
    }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
