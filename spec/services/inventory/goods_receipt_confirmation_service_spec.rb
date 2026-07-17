require "rails_helper"

RSpec.describe Inventory::GoodsReceiptConfirmationService, type: :model do
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

  def draft_receipt(qty: 10, cost: 50, funding_source_kind: "supplier_credit", funding_source: nil)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current,
                                      funding_source_kind: funding_source_kind, funding_source: funding_source)
    r.items.build(product: product, quantity: qty, unit_cost: cost)
    r.save!
    r
  end

  def confirm(receipt)
    described_class.new(goods_receipt_id: receipt.id, actor: actor).call
  end

  describe "supplier-credit (non-custody) receipts" do
    it "posts stock and confirms without touching any custody account or settlement" do
      receipt = draft_receipt
      result = confirm(receipt)

      expect(result.ok?).to be(true)
      expect(receipt.reload).to be_confirmed
      expect(product.reload.current_stock).to eq(10)
      expect(receipt.financial_settlements.count).to eq(0)
      expect(receipt).to be_pending_settlement
    end
  end

  describe "employee-custody-funded receipts" do
    it "deducts the balance and records a settlement plus a linked custody transaction" do
      top_up!(1000)
      receipt = draft_receipt(qty: 10, cost: 50, funding_source_kind: "employee_custody", funding_source: account)

      result = confirm(receipt)

      expect(result.ok?).to be(true)
      expect(receipt.reload).to be_confirmed
      expect(product.reload.current_stock).to eq(10)
      expect(account.reload.current_balance).to eq(500)

      settlement = receipt.financial_settlements.sole
      expect(settlement.amount).to eq(500)
      expect(settlement.funding_source).to eq(account)
      expect(receipt.total_settled_amount).to eq(500)
      expect(receipt).to be_settled

      txn = receipt.custody_transactions.of_type("inventory_purchase").first
      expect(txn).to be_present
      expect(txn.amount).to eq(-500)
      expect(txn.custody_account).to eq(account)
    end

    it "blocks confirmation when the balance is insufficient, posting no stock and creating no settlement or transaction" do
      top_up!(100)
      receipt = draft_receipt(qty: 10, cost: 50, funding_source_kind: "employee_custody", funding_source: account)

      result = confirm(receipt)

      expect(result.ok?).to be(false)
      expect(result.error).to eq(I18n.t("inventory.goods_receipts.errors.insufficient_custody_balance"))
      expect(receipt.reload).to be_draft
      expect(product.reload.current_stock).to eq(0)
      expect(account.reload.current_balance).to eq(100)
      expect(receipt.custody_transactions.count).to eq(0)
      expect(receipt.financial_settlements.count).to eq(0)
      expect(receipt).to be_pending_settlement
    end
  end

  describe "idempotency" do
    it "refuses to confirm an already-confirmed receipt" do
      receipt = draft_receipt
      confirm(receipt)

      result = confirm(receipt)
      expect(result.ok?).to be(false)
      expect(product.reload.current_stock).to eq(10) # unchanged, not double-posted
    end
  end
end
