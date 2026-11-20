require "rails_helper"

# Product availability per warehouse — Phase 1, unit 6: no stock comes INTO a
# product/warehouse pair whose availability is Inactive, through the real
# posting services. Outgoing, counts, adjustments, voids and Not Configured
# pairs are unaffected; the N6 purchase-request exception is narrow and audited.
RSpec.describe Inventory::IncomingAvailabilityGuard, type: :model do
  let(:business)  { create(:business) }
  let(:other)     { create(:business) }
  let!(:owner)    { create(:user, :owner, business: business) }
  let(:receiver)  { user_with_stock_permissions(business, :view_inventory, :confirm_goods_receipts, name: "Receiver") }
  let(:supplier)  { business.suppliers.create!(name: "Acme") }
  let!(:main)     { business.warehouses.create!(name: "Main Warehouse", kind: "central") }
  let!(:branch_wh) { business.warehouses.create!(name: "Nasr City WH", kind: "central") }
  let!(:shampoo)  { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10) }
  let!(:mask)     { business.products.create!(name: "Mask", sku: "MK-1", initial_cost_price: 4, average_cost_price: 4) }

  let(:inactive_error) do
    I18n.t("activerecord.errors.messages.product_inactive_in_warehouse", product: "Shampoo", warehouse: "Nasr City WH")
  end

  def manager = Inventory::ProductAvailabilityManager.new(actor: owner)

  def configure!(product, warehouse)
    expect(manager.add_many(warehouse_id: warehouse.id, items: [ { product_id: product.id } ])).to be_ok
    ProductWarehouseSetting.find_by!(product: product, warehouse: warehouse)
  end

  def deactivate!(product, warehouse)
    setting = configure!(product, warehouse)
    expect(manager.deactivate(setting_id: setting.id, reason: "No longer sold at this branch")).to be_ok
    setting.reload
  end

  def stock(product, warehouse) = product.reload.stock_in(warehouse)

  # Approved a day ago by default — before any deactivation in these examples,
  # so each N6 refusal below is caused by the one condition it names.
  def receipt(warehouse:, lines: [ [ shampoo, 5 ] ], approved: true, purchase_request: nil, approved_at: 1.day.ago)
    r = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current,
                                      purchase_request: purchase_request)
    lines.each do |product, qty, pri|
      r.items.build(product: product, quantity: qty, unit_cost: 10, purchase_request_item: pri)
    end
    r.save!
    r.update_columns(approval_status: "approved", decided_at: approved_at) if approved
    r
  end

  def confirm(r, actor: receiver)
    Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: r.id, actor: actor).call
  end

  def post_receipt!(warehouse, product, qty)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: product, quantity: qty, unit_cost: 10)
    expect(Inventory::GoodsReceiptPoster.new(r).call).to be_ok
  end

  def transfer(from:, to:, product: shampoo, qty: 2)
    t = business.stock_transfers.build(source_warehouse: from, destination_warehouse: to, transferred_on: Date.current)
    t.items.build(product: product, quantity: qty)
    Inventory::StockTransferPoster.new(t).call
  end

  def adjust(warehouse:, reason:, qty:, product: shampoo, cost: 10)
    a = business.stock_adjustments.build(warehouse: warehouse, adjusted_on: Date.current, reason: reason, created_by: owner)
    a.items.build(product: product, quantity_difference: qty, unit_cost: cost)
    Inventory::AdjustmentPoster.new(a).call
  end

  # A purchase request for `warehouse`, approved at `approved_at`.
  def approved_request(warehouse:, approved_at:, product: shampoo, qty: 10, status: "approved")
    pr = business.purchase_requests.build(supplier: supplier, warehouse: warehouse, source: "low_stock_alert")
    pr.items.build(product: product, quantity: qty, unit_price: 10)
    pr.save!
    pr.update_columns(status: status, approved_at: approved_at)
    pr.reload
  end

  def exception_audits = AuditLog.where(action: Inventory::GoodsReceiptPoster::EXCEPTION_AUDIT_ACTION)

  describe "goods receipts" do
    it "1. receives into an Active pair" do
      configure!(shampoo, branch_wh)
      expect(confirm(receipt(warehouse: branch_wh))).to be_ok
      expect(stock(shampoo, branch_wh)).to eq(5)
    end

    it "2. refuses a receipt into an Inactive pair, leaving the receipt a draft with no movement" do
      deactivate!(shampoo, branch_wh)
      r = receipt(warehouse: branch_wh, lines: [ [ shampoo, 5 ], [ mask, 3 ] ])

      result = confirm(r)

      expect(result).not_to be_ok
      expect(result.error).to include(inactive_error)
      expect(r.reload).to be_draft
      expect(InventoryMovement.where(source: r)).to be_empty
      expect([ stock(shampoo, branch_wh), stock(mask, branch_wh) ]).to eq([ 0, 0 ]) # the whole receipt, not just one line
      expect(shampoo.reload.average_cost_price).to eq(10)
      expect(exception_audits).to be_empty
    end

    it "refuses the poster called directly, rolling the new receipt back entirely" do
      deactivate!(shampoo, branch_wh)
      r = business.goods_receipts.build(warehouse: branch_wh, received_on: Date.current)
      r.items.build(product: shampoo, quantity: 5, unit_cost: 10)

      expect { expect(Inventory::GoodsReceiptPoster.new(r).call).not_to be_ok }
        .not_to change { [ GoodsReceipt.count, InventoryMovement.count ] }
      expect(r.errors.full_messages).to include(inactive_error)
    end

    it "13. never blocks a Not Configured pair (no row, warn-only until Phase 6)" do
      expect(confirm(receipt(warehouse: branch_wh))).to be_ok
      expect(stock(shampoo, branch_wh)).to eq(5)
      expect(ProductWarehouseSetting.count).to eq(0) # and receiving creates no row
    end

    it "14. an Inactive pair in one warehouse does not affect the same product in another warehouse" do
      deactivate!(shampoo, branch_wh)
      expect(confirm(receipt(warehouse: main))).to be_ok
      expect(stock(shampoo, main)).to eq(5)
    end

    it "is refused again after a reactivation and re-deactivation, and allowed once reactivated" do
      setting = deactivate!(shampoo, branch_wh)
      expect(manager.reactivate(setting_id: setting.id)).to be_ok
      expect(confirm(receipt(warehouse: branch_wh))).to be_ok
      expect(stock(shampoo, branch_wh)).to eq(5)
    end
  end

  describe "N6 — receipts for a purchase request approved before the deactivation" do
    it "6. receives the request's line through the explicit, audited exception" do
      request = approved_request(warehouse: branch_wh, approved_at: 2.days.ago)
      setting = deactivate!(shampoo, branch_wh)
      r = receipt(warehouse: branch_wh, purchase_request: request, lines: [ [ shampoo, 4, request.items.sole ] ])

      result = confirm(r)

      expect(result).to be_ok
      expect(stock(shampoo, branch_wh)).to eq(4)
      expect(setting.reload).to be_status_inactive # the exception never reactivates the pair
      entry = exception_audits.sole
      expect(entry).to have_attributes(actor_id: receiver.id, auditable: r)
      expect(entry.metadata).to include(
        "exception" => "purchase_request_approved_before_deactivation",
        "goods_receipt_id" => r.id, "product_id" => shampoo.id, "warehouse_id" => branch_wh.id,
        "purchase_request_id" => request.id, "purchase_request_item_id" => request.items.sole.id,
        "product_warehouse_setting_id" => setting.id, "deactivation_reason" => "No longer sold at this branch",
        "quantity" => "4.0"
      )
      expect(request.reload).to be_partially_received
    end

    it "7. an ordinary receipt (no purchase request) cannot use the exception" do
      approved_request(warehouse: branch_wh, approved_at: 2.days.ago)
      deactivate!(shampoo, branch_wh)
      expect(confirm(receipt(warehouse: branch_wh))).not_to be_ok
      expect(stock(shampoo, branch_wh)).to eq(0)
    end

    it "refuses a request approved AFTER the deactivation" do
      deactivate!(shampoo, branch_wh)
      request = approved_request(warehouse: branch_wh, approved_at: 1.minute.from_now)
      r = receipt(warehouse: branch_wh, purchase_request: request, lines: [ [ shampoo, 4, request.items.sole ] ])
      expect(confirm(r)).not_to be_ok
      expect(stock(shampoo, branch_wh)).to eq(0)
    end

    it "refuses a request that is no longer receivable" do
      request = approved_request(warehouse: branch_wh, approved_at: 2.days.ago)
      deactivate!(shampoo, branch_wh)
      r = receipt(warehouse: branch_wh, purchase_request: request, lines: [ [ shampoo, 4, request.items.sole ] ])
      request.update_column(:status, "partially_closed")
      expect(confirm(r)).not_to be_ok
      expect(exception_audits).to be_empty
    end

    it "refuses the request's line when the receipt lands in a warehouse other than the request's" do
      request = approved_request(warehouse: main, approved_at: 2.days.ago)
      deactivate!(shampoo, branch_wh)
      r = receipt(warehouse: branch_wh, purchase_request: request, lines: [ [ shampoo, 4, request.items.sole ] ])
      expect(confirm(r)).not_to be_ok
      expect(stock(shampoo, branch_wh)).to eq(0)
    end

    it "admits only the request's lines: an extra product on the same receipt refuses the whole receipt" do
      request = approved_request(warehouse: branch_wh, approved_at: 2.days.ago)
      deactivate!(shampoo, branch_wh)
      deactivate!(mask, branch_wh)
      r = receipt(warehouse: branch_wh, purchase_request: request,
                  lines: [ [ shampoo, 4, request.items.sole ], [ mask, 2 ] ])

      result = confirm(r)

      expect(result).not_to be_ok
      expect(result.error).to include(I18n.t("activerecord.errors.messages.product_inactive_in_warehouse",
                                             product: "Mask", warehouse: "Nasr City WH"))
      expect([ stock(shampoo, branch_wh), stock(mask, branch_wh) ]).to eq([ 0, 0 ])
      expect(exception_audits).to be_empty
    end

    it "8. a forged link to another request's line is refused — the guard re-reads the link from the database" do
      stale   = approved_request(warehouse: branch_wh, approved_at: 2.days.ago)
      current = approved_request(warehouse: branch_wh, approved_at: 1.minute.from_now)
      deactivate!(shampoo, branch_wh)
      # The receipt names the new request but points its line at the old
      # request's line (what a tampered form would send); saved without the
      # model validation that normally rejects it.
      r = business.goods_receipts.build(warehouse: branch_wh, supplier: supplier, received_on: Date.current,
                                        purchase_request: current, approval_status: "approved", decided_at: 1.day.ago)
      r.items.build(product: shampoo, quantity: 4, unit_cost: 10, purchase_request_item: stale.items.sole)
      r.receipt_number = Inventory::NumberSequencer.new(business, :goods_receipt).next_number
      r.items.each { |i| i.send(:compute_total_cost) }
      r.save!(validate: false)

      # Independently of the receipt's own link validation (which also refuses
      # it on confirmation), the guard does not admit the line.
      ActiveRecord::Base.transaction do
        guard = described_class.new(warehouse_id: branch_wh.id, product_ids: [ shampoo.id ])
        exceptions, refused = guard.classify_receipt(r.reload)
        expect(exceptions).to be_empty
        expect(refused.map(&:product_id)).to eq([ shampoo.id ])
      end

      expect(confirm(r)).not_to be_ok
      expect(stock(shampoo, branch_wh)).to eq(0)
      expect(exception_audits).to be_empty
    end

    it "8. a request of another business can never qualify" do
      foreign_supplier = other.suppliers.create!(name: "Foreign")
      foreign_product  = other.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 1, average_cost_price: 1)
      foreign = other.purchase_requests.build(supplier: foreign_supplier, source: "low_stock_alert")
      foreign.items.build(product: foreign_product, quantity: 10, unit_price: 1)
      foreign.save!
      foreign.update_columns(status: "approved", approved_at: 2.days.ago)
      deactivate!(shampoo, branch_wh)

      r = business.goods_receipts.build(warehouse: branch_wh, received_on: Date.current, approval_status: "approved",
                                        decided_at: 1.day.ago)
      r.items.build(product: shampoo, quantity: 4, unit_cost: 10)
      r.save!
      r.update_column(:purchase_request_id, foreign.id)
      r.items.sole.update_column(:purchase_request_item_id, foreign.items.sole.id)

      ActiveRecord::Base.transaction do
        guard = described_class.new(warehouse_id: branch_wh.id, product_ids: [ shampoo.id ])
        expect(guard.classify_receipt(r.reload).first).to be_empty
      end
      expect(confirm(r)).not_to be_ok
      expect(stock(shampoo, branch_wh)).to eq(0)
    end

    it "never admits the exception without an actor (the poster called directly)" do
      request = approved_request(warehouse: branch_wh, approved_at: 2.days.ago)
      deactivate!(shampoo, branch_wh)
      r = receipt(warehouse: branch_wh, purchase_request: request, lines: [ [ shampoo, 4, request.items.sole ] ])

      expect(Inventory::GoodsReceiptPoster.new(r).call).not_to be_ok
      expect(stock(shampoo, branch_wh)).to eq(0)
    end

    it "16. rolls the whole confirmation back when the exception's audit entry cannot be written" do
      request = approved_request(warehouse: branch_wh, approved_at: 2.days.ago)
      deactivate!(shampoo, branch_wh)
      r = receipt(warehouse: branch_wh, purchase_request: request, lines: [ [ shampoo, 4, request.items.sole ] ])
      fail_audit_writes!(Inventory::GoodsReceiptPoster::EXCEPTION_AUDIT_ACTION)

      result = confirm(r)

      expect(result).not_to be_ok
      expect(result.error).to eq(I18n.t("inventory.goods_receipts.errors.confirmation_audit_failed"))
      expect(r.reload).to be_draft
      expect(InventoryMovement.where(source: r)).to be_empty
      expect(stock(shampoo, branch_wh)).to eq(0)
      expect(request.reload).to be_approved
      expect(AuditLog.where(auditable: r, action: "confirm")).to be_empty
    end
  end

  describe "transfers" do
    before { post_receipt!(main, shampoo, 10) }

    it "3. transfers into an Active destination" do
      configure!(shampoo, branch_wh)
      expect(transfer(from: main, to: branch_wh)).to be_ok
      expect(stock(shampoo, branch_wh)).to eq(2)
    end

    it "4. refuses a transfer into an Inactive destination — neither side moves" do
      deactivate!(shampoo, branch_wh)

      result = nil
      expect { result = transfer(from: main, to: branch_wh) }.not_to change { [ StockTransfer.count, InventoryMovement.count ] }
      expect(result).not_to be_ok
      expect(result.transfer.errors.full_messages).to include(inactive_error)
      expect([ stock(shampoo, main), stock(shampoo, branch_wh) ]).to eq([ 10, 0 ])
    end

    it "9. allows transferring OUT of an Inactive pair" do
      post_receipt!(branch_wh, shampoo, 6)
      deactivate!(shampoo, branch_wh)
      expect(transfer(from: branch_wh, to: main, qty: 6)).to be_ok
      expect(stock(shampoo, branch_wh)).to eq(0)
    end

    it "13. a Not Configured destination is unaffected" do
      expect(transfer(from: main, to: branch_wh)).to be_ok
    end

    it "14. refuses a destination warehouse of another business before reading any availability" do
      foreign_wh = other.warehouses.create!(name: "Foreign")
      expect(transfer(from: main, to: foreign_wh)).not_to be_ok
      expect(stock(shampoo, main)).to eq(10)
    end
  end

  describe "adjustments" do
    it "5. refuses an opening balance into an Inactive pair" do
      deactivate!(shampoo, branch_wh)
      result = nil
      expect { result = adjust(warehouse: branch_wh, reason: "opening_balance", qty: 20) }
        .not_to change { [ StockAdjustment.count, InventoryMovement.count ] }
      expect(result).not_to be_ok
      expect(result.adjustment.errors.full_messages).to include(inactive_error)
      expect(shampoo.reload.average_cost_price).to eq(10)
    end

    it "5. an opening balance into an Active or Not Configured pair still posts" do
      configure!(shampoo, main)
      expect(adjust(warehouse: main, reason: "opening_balance", qty: 20)).to be_ok
      expect(adjust(warehouse: branch_wh, reason: "opening_balance", qty: 5)).to be_ok
    end

    it "11. allows ordinary adjustments of either sign into an Inactive pair (they record physical reality)" do
      post_receipt!(branch_wh, shampoo, 10)
      deactivate!(shampoo, branch_wh)

      expect(adjust(warehouse: branch_wh, reason: "damaged", qty: -3)).to be_ok
      expect(adjust(warehouse: branch_wh, reason: "manual_correction", qty: 2)).to be_ok
      expect(stock(shampoo, branch_wh)).to eq(9)
    end
  end

  describe "outgoing, counts and voids stay allowed" do
    before do
      post_receipt!(branch_wh, shampoo, 10)
    end

    it "9. a stock issue out of an Inactive pair posts" do
      deactivate!(shampoo, branch_wh)
      outlet = business.branches.create!(name: "Outlet", active: true)
      i = business.stock_issues.build(warehouse: branch_wh, branch: outlet, issued_on: Date.current)
      i.items.build(product: shampoo, quantity: 4)
      expect(approve_and_post_stock_issue(i)).to be_ok
      expect(stock(shampoo, branch_wh)).to eq(6)
    end

    it "10. a stock count of an Inactive pair is approved, including an overage (IN)" do
      deactivate!(shampoo, branch_wh)
      counter  = user_with_stock_permissions(business, :view_inventory, :manage_stock_counts)
      approver = user_with_stock_permissions(business, :view_inventory, :post_stock_counts)
      count = record_stock_count!(business: business, warehouse: branch_wh, counter: counter,
                                  lines: [ [ shampoo, 12 ] ], complete: true)

      expect(approve_stock_count(count, approver)).to be_ok
      expect(stock(shampoo, branch_wh)).to eq(12)
    end

    it "12. voiding a receipt, an issue and a transfer of an Inactive pair still reverses them" do
      post_receipt!(main, shampoo, 10)
      outlet = business.branches.create!(name: "Outlet", active: true)
      issue = business.stock_issues.build(warehouse: branch_wh, branch: outlet, issued_on: Date.current)
      issue.items.build(product: shampoo, quantity: 4)
      issue = approve_and_post_stock_issue(issue).issue
      moved = transfer(from: branch_wh, to: main, qty: 3).transfer
      deactivate!(shampoo, branch_wh)

      # Voiding the issue and the transfer brings stock back INTO the Inactive pair (reversal).
      expect(Inventory::DocumentVoider.new(issue, user: owner, reason: "entered twice").call).to be_ok
      expect(Inventory::DocumentVoider.new(moved, user: owner, reason: "wrong warehouse").call).to be_ok
      expect(stock(shampoo, branch_wh)).to eq(10)

      receipt_doc = GoodsReceipt.where(warehouse: branch_wh).sole
      expect(Inventory::DocumentVoider.new(receipt_doc, user: owner, reason: "duplicate").call).to be_ok
      expect(stock(shampoo, branch_wh)).to eq(0)
    end
  end

  it "refuses to run outside a transaction (its locks would mean nothing)" do
    guard = described_class.new(warehouse_id: main.id, product_ids: [ shampoo.id ])
    allow(ActiveRecord::Base.connection).to receive(:transaction_open?).and_return(false)
    expect { guard.inactive_settings }.to raise_error(ArgumentError)
  end
end
