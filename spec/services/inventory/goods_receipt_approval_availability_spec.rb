require "rails_helper"

# Phase 1 unit 6: a goods receipt with a line for a product that is already
# Inactive in the receipt's warehouse is never APPROVED (approval is the
# financial event; such a receipt could never be received). A receipt approved
# before the deactivation keeps the narrow, audited N6 path at confirmation.
RSpec.describe Inventory::GoodsReceiptApproval, "and product availability", type: :model do
  let(:business)  { create(:business) }
  let(:other)     { create(:business) }
  let!(:owner)    { create(:user, :owner, business: business) }
  let(:requester) { create(:user, business: business) }
  let(:approver)  { create(:user, business: business) }
  let(:receiver)  { user_with_stock_permissions(business, :view_inventory, :confirm_goods_receipts, name: "Receiver") }
  let(:supplier)  { business.suppliers.create!(name: "Acme") }
  let!(:main)     { business.warehouses.create!(name: "Main Warehouse", kind: "central") }
  let!(:branch_wh) { business.warehouses.create!(name: "Nasr City WH", kind: "central") }
  let!(:shampoo)  { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10) }
  let!(:mask)     { business.products.create!(name: "Mask", sku: "MK-1", initial_cost_price: 4, average_cost_price: 4) }

  def manager = Inventory::ProductAvailabilityManager.new(actor: owner)

  def configure!(product, warehouse)
    expect(manager.add_many(warehouse_id: warehouse.id, items: [ { product_id: product.id } ])).to be_ok
    ProductWarehouseSetting.find_by!(product: product, warehouse: warehouse)
  end

  def deactivate!(product, warehouse)
    setting = configure!(product, warehouse)
    expect(manager.deactivate(setting_id: setting.id, reason: "No longer sold here")).to be_ok
    setting.reload
  end

  # Submitted for approval by the requester, paid in cash on approval (so a
  # wrongly approved receipt would leave a FinancialSettlement behind).
  def pending_receipt(warehouse: branch_wh, lines: [ [ shampoo, 5 ] ], purchase_request: nil, kind: "company_cash")
    r = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current,
                                      created_by: requester, funding_source_kind: kind, purchase_request: purchase_request)
    lines.each { |product, qty, pri| r.items.build(product: product, quantity: qty, unit_cost: 10, purchase_request_item: pri) }
    r.save!
    expect(described_class.new(goods_receipt_id: r.id, actor: requester).submit!).to be_ok
    r.reload
  end

  def approve(receipt, actor: approver) = described_class.new(goods_receipt_id: receipt.id, actor: actor).approve!
  def confirm(receipt) = Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: receipt.id, actor: receiver).call

  def approved_request(warehouse: branch_wh, approved_at: 2.days.ago)
    pr = business.purchase_requests.build(supplier: supplier, warehouse: warehouse, source: "low_stock_alert")
    pr.items.build(product: shampoo, quantity: 10, unit_price: 10)
    pr.save!
    pr.update_columns(status: "approved", approved_at: approved_at)
    pr.reload
  end

  def inactive_message(product = "Shampoo", warehouse = "Nasr City WH")
    I18n.t("activerecord.errors.messages.product_inactive_in_warehouse", product: product, warehouse: warehouse)
  end

  def expect_untouched(receipt)
    receipt.reload
    expect(receipt.approval_status).to eq("pending_approval")
    expect([ receipt.decided_at, receipt.decided_by_id ]).to eq([ nil, nil ])
    expect(receipt.financial_settlements).to be_empty
    expect(InventoryMovement.where(source: receipt)).to be_empty
    expect(AuditLog.where(auditable: receipt, action: "approve")).to be_empty
  end

  it "1. refuses approval when a line's pair is already Inactive, with no approval, payment or movement" do
    deactivate!(shampoo, branch_wh)
    receipt = pending_receipt

    result = approve(receipt)

    expect(result).not_to be_ok
    expect(result.error).to eq(inactive_message)
    expect_untouched(receipt)
  end

  it "1. refuses it for the owner too (no permission overrides availability)" do
    deactivate!(shampoo, branch_wh)
    receipt = pending_receipt
    expect(approve(receipt, actor: owner)).not_to be_ok
    expect_untouched(receipt)
  end

  it "2. approves a receipt into an Active pair (cash paid on approval)" do
    configure!(shampoo, branch_wh)
    receipt = pending_receipt
    expect(approve(receipt)).to be_ok
    expect(receipt.reload).to be_approval_approved
    expect(receipt.financial_settlements.sole.amount).to eq(50)
  end

  it "3. approves a receipt into a Not Configured pair, unaffected" do
    receipt = pending_receipt
    expect(approve(receipt)).to be_ok
    expect(ProductWarehouseSetting.count).to eq(0)
  end

  it "6. a multi-line receipt with one Inactive line is refused as a whole, naming that line" do
    configure!(mask, branch_wh)
    deactivate!(shampoo, branch_wh)
    receipt = pending_receipt(lines: [ [ mask, 2 ], [ shampoo, 5 ] ])

    result = approve(receipt)

    expect(result.error).to eq(inactive_message)
    expect(result.error).not_to include("Mask")
    expect_untouched(receipt)
  end

  it "7. a refused receipt from a purchase request consumes no advance and leaves the request untouched" do
    request = approved_request
    deactivate!(shampoo, branch_wh)
    receipt = pending_receipt(purchase_request: request, lines: [ [ shampoo, 4, request.items.sole ] ])

    expect(approve(receipt)).not_to be_ok
    expect_untouched(receipt)
    expect(request.reload).to be_approved
  end

  it "4. a receipt approved BEFORE the deactivation is still received through the audited N6 exception" do
    request = approved_request
    receipt = pending_receipt(purchase_request: request, lines: [ [ shampoo, 4, request.items.sole ] ], kind: "supplier_credit")
    travel_to(1.hour.ago) { expect(approve(receipt)).to be_ok }
    deactivate!(shampoo, branch_wh)

    expect(confirm(receipt)).to be_ok
    expect(shampoo.reload.stock_in(branch_wh)).to eq(4)
    entry = AuditLog.find_by!(action: Inventory::GoodsReceiptPoster::EXCEPTION_AUDIT_ACTION, auditable: receipt)
    expect(entry.metadata).to include("purchase_request_id" => request.id, "receipt_approved_at" => receipt.reload.decided_at.iso8601)
  end

  it "4. an ordinary receipt approved before the deactivation is NOT admitted (N6 needs a purchase request)" do
    receipt = pending_receipt(kind: "supplier_credit")
    travel_to(1.hour.ago) { expect(approve(receipt)).to be_ok }
    deactivate!(shampoo, branch_wh)

    result = confirm(receipt)
    expect(result).not_to be_ok
    expect(result.error).to include(inactive_message)
    expect(receipt.reload).to be_draft
  end

  it "5. a receipt approved AFTER the deactivation (e.g. before this rule existed) never qualifies for N6" do
    request = approved_request
    deactivate!(shampoo, branch_wh)
    receipt = pending_receipt(purchase_request: request, lines: [ [ shampoo, 4, request.items.sole ] ], kind: "supplier_credit")
    # Approval is refused now, so simulate a receipt approved after the
    # deactivation by a path that no longer exists.
    receipt.update_columns(approval_status: "approved", decided_at: 1.minute.from_now, decided_by_id: approver.id)

    expect(confirm(receipt)).not_to be_ok
    expect(shampoo.reload.stock_in(branch_wh)).to eq(0)
    expect(AuditLog.where(action: Inventory::GoodsReceiptPoster::EXCEPTION_AUDIT_ACTION)).to be_empty
  end

  describe "8. cross-warehouse and cross-business" do
    it "an Inactive pair in another warehouse does not block approval in this one" do
      deactivate!(shampoo, main)
      expect(approve(pending_receipt(warehouse: branch_wh))).to be_ok
    end

    it "another business's approver cannot reach the receipt at all" do
      deactivate!(shampoo, branch_wh)
      receipt  = pending_receipt
      outsider = create(:user, business: other)
      expect { approve(receipt, actor: outsider) }.to raise_error(ActiveRecord::RecordNotFound)
      expect_untouched(receipt)
    end

    it "another business's Inactive row for a same-named product never affects this business" do
      foreign_wh      = other.warehouses.create!(name: "Nasr City WH", kind: "central")
      foreign_product = other.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 1, average_cost_price: 1)
      foreign_owner   = create(:user, :owner, business: other)
      foreign_manager = Inventory::ProductAvailabilityManager.new(actor: foreign_owner)
      foreign_manager.add_many(warehouse_id: foreign_wh.id, items: [ { product_id: foreign_product.id } ])
      foreign_manager.deactivate(setting_id: ProductWarehouseSetting.find_by!(product: foreign_product).id, reason: "x")

      expect(approve(pending_receipt)).to be_ok
    end
  end
end
