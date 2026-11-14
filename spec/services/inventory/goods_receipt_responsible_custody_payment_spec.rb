require "rails_helper"

# A Goods Receipt from a Purchase Request may be paid from custody only by the
# request's responsible employee — their custody, which received the request's
# funding, is the one debited (PurchaseRequest#custody_payment_refusal) — and
# not at all while the request has none. Enforced on the receipt (model), at
# approval and for later payments; other funding sources are unaffected. A
# receipt with no Purchase Request keeps the old rule.
RSpec.describe "Goods Receipt custody payment by the responsible employee", type: :model do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let(:approver)  { create(:user, business: business) }
  let(:supplier)  { business.suppliers.create!(name: "Nile Beauty") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", average_cost_price: 100) }
  let(:rami)  { purchaser_with_custody(business, first_name: "Rami", balance: 1000) }
  let(:other) { purchaser_with_custody(business, first_name: "Omar", balance: 1000) }

  let(:request) do
    pr = business.purchase_requests.build(warehouse: warehouse, created_by: owner, responsible_employee: rami)
    pr.items.build(product: product, quantity: 5, unit_price: 100, supplier: supplier)
    pr.save!
    pr.update_column(:status, "approved")
    pr
  end

  def draft(actor:, kind: "employee_custody", purchase_request: request)
    receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, purchase_request: purchase_request,
                                            received_on: Date.current, created_by: actor, funding_source_kind: kind)
    receipt.items.build(product: product, quantity: 2, unit_cost: 100,
                        purchase_request_item: purchase_request.items.sole)
    Inventory::GoodsReceiptDraftService.new(receipt, actor: actor).call
  end

  def approve(receipt)
    receipt.update_column(:approval_status, "pending_approval")
    Inventory::GoodsReceiptApproval.new(goods_receipt_id: receipt.id, actor: approver).approve!
  end

  def responsible_only = I18n.t("activerecord.errors.models.goods_receipt.attributes.base.custody_payment_responsible_only")

  it "the responsible employee pays from their own custody: approval debits it" do
    # Fund Rami first (company cash) — posted when recorded.
    expect(Inventory::PurchaseRequestAdvanceRecorder.new(
      purchase_request_id: request.id, actor: owner, params: { amount: 300, source_kind: "company_cash", paid_on: Date.current }
    ).call).to be_ok
    expect(custody_of(rami).reload.current_balance).to eq(1300)

    result = draft(actor: rami)
    expect(result).to be_ok
    expect(result.receipt.funding_source).to eq(custody_of(rami))
    expect(approve(result.receipt)).to be_ok

    expect(custody_of(rami).reload.current_balance).to eq(1100) # 1,300 − 200 receipt
    expect(CustodyTransaction.where(txn_type: "inventory_purchase").sole)
      .to have_attributes(custody_account_id: custody_of(rami).id, amount: -200)
    expect(custody_of(other).reload.current_balance).to eq(1000)
  end

  it "another employee can't pay this receipt from their own custody (model)" do
    result = draft(actor: other)
    expect(result).not_to be_ok
    expect(result.receipt.errors.full_messages).to include(responsible_only)
    expect(GoodsReceipt.count).to eq(0)
  end

  it "another employee may still record the receipt with a non-custody funding source" do
    expect(draft(actor: other, kind: "supplier_credit")).to be_ok
  end

  it "re-checks at approval (the responsible employee changed after the draft)" do
    receipt = draft(actor: rami).receipt
    request.update_column(:responsible_employee_id, other.id)

    result = approve(receipt.reload)
    expect(result.error).to eq(responsible_only)
    expect(receipt.reload.approval_status).to eq("pending_approval")
    expect(custody_of(rami).reload.current_balance).to eq(1000)
  end

  it "later payments from custody: only the responsible employee" do
    receipt = draft(actor: owner, kind: "supplier_credit").receipt
    expect(approve(receipt)).to be_ok

    pay = ->(actor) {
      Inventory::GoodsReceiptSettlementRecorder.new(receipt.id, actor: actor,
                                                    params: { source_kind: "employee_custody", amount: "50" }).call
    }
    expect(pay.(other).error).to eq(I18n.t("inventory.goods_receipts.settlements.errors.custody_payment_responsible_only"))
    expect(pay.(rami)).to be_ok
    expect(custody_of(rami).reload.current_balance).to eq(950)
    expect(custody_of(other).reload.current_balance).to eq(1000)
  end

  describe "a request without a responsible employee" do
    let(:unassigned) do
      pr = business.purchase_requests.build(warehouse: warehouse, created_by: owner)
      pr.items.build(product: product, quantity: 5, unit_price: 100, supplier: supplier)
      pr.save!
      pr.update_column(:status, "approved")
      pr
    end
    let(:requires_responsible) do
      I18n.t("activerecord.errors.models.goods_receipt.attributes.base.custody_payment_requires_responsible")
    end

    it "blocks custody payment for everyone (no automatic assignment), but not other funding sources" do
      [ rami, other ].each do |actor|
        result = draft(actor: actor, purchase_request: unassigned)
        expect(result).not_to be_ok
        expect(result.receipt.errors.full_messages).to include(requires_responsible)
      end
      expect(unassigned.reload.responsible_employee_id).to be_nil
      expect(draft(actor: other, kind: "company_cash", purchase_request: unassigned)).to be_ok
    end

    it "blocks a later custody payment, then allows it from the responsible employee's custody once assigned" do
      receipt = draft(actor: owner, kind: "supplier_credit", purchase_request: unassigned).receipt
      expect(approve(receipt)).to be_ok
      pay = ->(actor) {
        Inventory::GoodsReceiptSettlementRecorder.new(receipt.id, actor: actor,
                                                      params: { source_kind: "employee_custody", amount: "50" }).call
      }

      expect(pay.(rami).error).to eq(I18n.t("inventory.goods_receipts.settlements.errors.custody_payment_requires_responsible"))
      expect(Inventory::PurchaseRequestResponsibleAssigner.new(unassigned.id, actor: owner,
                                                                responsible_employee_id: rami.id).call).to be_ok
      expect(pay.(rami)).to be_ok
      expect(custody_of(rami).reload.current_balance).to eq(950)
    end

    it "re-checks at approval: a custody draft made before the employee was removed is refused" do
      receipt = draft(actor: rami).receipt
      request.update_column(:responsible_employee_id, nil)

      expect(approve(receipt.reload).error).to eq(requires_responsible)
      expect(custody_of(rami).reload.current_balance).to eq(1000)
    end
  end

  it "a receipt with no Purchase Request keeps the old rule (the acting user's own custody)" do
    receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current,
                                            created_by: other, funding_source_kind: "employee_custody")
    receipt.items.build(product: product, quantity: 1, unit_cost: 100)
    result = Inventory::GoodsReceiptDraftService.new(receipt, actor: other).call
    expect(result).to be_ok
    expect(result.receipt.funding_source).to eq(custody_of(other))
  end
end
