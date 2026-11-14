require "rails_helper"

# Historical Purchase Requests (no responsible employee) and their Goods
# Receipts under the custody payment rule (PurchaseRequest#custody_payment_refusal):
#   - an APPROVED receipt and its payments stay exactly as they are — the rule
#     only judges a receipt when its payer or request changes, and at approval;
#   - a PENDING receipt that pays from custody is not approved until an
#     eligible responsible employee is assigned — never automatically — and then
#     only when its custody is that employee's;
#   - no historical settlement or custody row is changed.
# Each receipt is put in the state it was saved in before the rule (columns
# written directly), as the historical rows are.
RSpec.describe "Goods Receipt custody payment on historical Purchase Requests", type: :model do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let(:approver)  { create(:user, business: business) }
  let(:supplier)  { business.suppliers.create!(name: "Nile Beauty") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", average_cost_price: 100) }
  let(:holder) { purchaser_with_custody(business, first_name: "Hana", balance: 1000) } # drafted the receipt
  let!(:other) { purchaser_with_custody(business, first_name: "Omar", balance: 1000) }

  # A request created before the responsible employee existed.
  let(:legacy_request) do
    pr = business.purchase_requests.build(supplier: supplier, created_by: owner)
    pr.items.build(product: product, quantity: 5, unit_price: 100, source_warehouse: warehouse)
    pr.save!
    pr.update_column(:status, "approved")
    pr
  end

  # A receipt from it paid from `holder`'s custody, saved as the old rule allowed.
  def historical_custody_receipt(approval_status:)
    receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, purchase_request: legacy_request,
                                            received_on: Date.current, created_by: holder,
                                            funding_source_kind: "supplier_credit")
    receipt.items.build(product: product, quantity: 2, unit_cost: 100, purchase_request_item: legacy_request.items.sole)
    receipt.save!
    receipt.update_columns(funding_source_kind: "employee_custody", funding_source_type: "CustodyAccount",
                           funding_source_id: custody_of(holder).id, approval_status: approval_status)
    receipt.reload
  end

  def approve(receipt) = Inventory::GoodsReceiptApproval.new(goods_receipt_id: receipt.id, actor: approver).approve!
  def assign(user) = Inventory::PurchaseRequestResponsibleAssigner.new(legacy_request.id, actor: owner,
                                                                        responsible_employee_id: user.id).call
  def base_error(key) = I18n.t("activerecord.errors.models.goods_receipt.attributes.base.#{key}")

  def financial_snapshot
    { settlements: FinancialSettlement.pluck(:id, :amount, :reverses_settlement_id).sort,
      custody: CustodyTransaction.order(:id).pluck(:id, :custody_account_id, :amount, :voided_at),
      balances: [ custody_of(holder).reload.current_balance, custody_of(other).reload.current_balance ] }
  end

  describe "an already approved receipt" do
    # Approved and paid from custody while the old rule applied: approval ran
    # with the drafter as the request's payer, then the request is back to its
    # historical state (no responsible employee).
    let!(:approved) do
      receipt = historical_custody_receipt(approval_status: "pending_approval")
      legacy_request.update_column(:responsible_employee_id, holder.id)
      expect(approve(receipt)).to be_ok
      legacy_request.update_column(:responsible_employee_id, nil)
      receipt.reload
    end

    it "keeps its payment and the custody debit untouched, and is not re-judged by the rule" do
      expect(approved).to be_approval_approved
      expect(custody_of(holder).reload.current_balance).to eq(800)
      snapshot = financial_snapshot

      expect(approved.reload).to be_valid
      # The rule would refuse it now, yet it stays valid: judged only when its payer or request changes.
      expect(approved.custody_payment_refusal).to eq(:custody_payment_requires_responsible)
      expect(financial_snapshot).to eq(snapshot)
      expect(legacy_request.reload.responsible_employee_id).to be_nil
    end

    it "is still received into stock as before" do
      result = Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: approved.id, actor: owner).call
      expect(result).to be_ok
      expect(approved.reload).to be_confirmed
      expect(product.reload.current_stock).to eq(2)
    end
  end

  describe "a pending receipt that pays from custody" do
    let!(:pending) { historical_custody_receipt(approval_status: "pending_approval") }

    it "is not approved while the request has no responsible employee — nothing is written, nobody assigned" do
      snapshot = financial_snapshot
      result = approve(pending)

      expect(result.error).to eq(base_error(:custody_payment_requires_responsible))
      expect(pending.reload.approval_status).to eq("pending_approval")
      expect(financial_snapshot).to eq(snapshot)
      expect(legacy_request.reload.responsible_employee_id).to be_nil
    end

    it "is approved once its own custody holder is assigned as the eligible responsible employee" do
      expect(approve(pending)).not_to be_ok
      expect(assign(holder)).to be_ok

      expect(approve(pending)).to be_ok
      expect(pending.reload).to be_approval_approved
      expect(CustodyTransaction.where(txn_type: "inventory_purchase").sole)
        .to have_attributes(custody_account_id: custody_of(holder).id, amount: -200)
      expect(custody_of(holder).reload.current_balance).to eq(800)
    end

    it "is still refused when someone else is assigned: custody only from the responsible employee's account" do
      expect(assign(other)).to be_ok
      snapshot = financial_snapshot

      expect(approve(pending).error).to eq(base_error(:custody_payment_responsible_only))
      expect(pending.reload.approval_status).to eq("pending_approval")
      expect(financial_snapshot).to eq(snapshot)
    end

    it "an ineligible employee cannot be assigned to unlock it" do
      no_permission = create(:user, business: business).tap { |u| create(:custody_account, business: business, user: u) }
      expect(assign(no_permission).error).to eq(I18n.t("inventory.purchase_requests.errors.responsible_employee_ineligible"))
      expect(approve(pending).error).to eq(base_error(:custody_payment_requires_responsible))
    end
  end

  it "a pending receipt with another funding source is approved as before, without a responsible employee" do
    receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, purchase_request: legacy_request,
                                            received_on: Date.current, created_by: holder, funding_source_kind: "company_cash")
    receipt.items.build(product: product, quantity: 1, unit_cost: 100, purchase_request_item: legacy_request.items.sole)
    receipt.save!
    receipt.update_column(:approval_status, "pending_approval")

    expect(approve(receipt)).to be_ok
    expect(receipt.reload.financial_settlements.sole).to have_attributes(source_kind: "company_cash", amount: 100)
    expect(legacy_request.reload.responsible_employee_id).to be_nil
  end
end
