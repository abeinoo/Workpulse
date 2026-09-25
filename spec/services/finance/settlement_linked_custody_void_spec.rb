require "rails_helper"

# A custody movement linked to a FinancialSettlement (goods receipt payment
# from custody, or the credit of its reversal) must never be voided directly —
# only undone by reversing the settlement, so custody and the receipt's paid
# amount can't diverge.
RSpec.describe "Settlement-linked custody transactions — direct void protection", type: :model do
  let(:business)  { create(:business) }
  let(:admin)     { create(:user, :super_admin, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product) do
    business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0)
  end
  let(:ahmed)   { create(:user, business: business) }
  let(:account) { create(:custody_account, business: business, user: ahmed) }

  let!(:receipt) do
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current, funding_source_kind: "supplier_credit")
    r.items.build(product: product, quantity: 100, unit_cost: 50) # 5,000
    r.save!
    r.update_column(:approval_status, "pending_approval")
    Inventory::GoodsReceiptApproval.new(goods_receipt_id: r.id, actor: admin).approve!
    r.reload
  end

  before do
    account.custody_transactions.create!(business: business, txn_type: "top_up", amount: 10_000)
    account.refresh_balance!
  end

  def settle(**params)
    # Ahmed records it: Employee Custody is always the recorder's own account.
    Inventory::GoodsReceiptSettlementRecorder.new(receipt.id, actor: ahmed, params: params).call.tap do |r|
      raise r.error unless r.ok?
    end.settlement
  end

  def reverse(settlement, reason: "Wrong custody")
    Inventory::GoodsReceiptSettlementReverser.new(goods_receipt_id: receipt.id, settlement_id: settlement.id,
                                                  actor: admin, reason: reason).call
  end

  def direct_void(txn)
    Finance::TransactionVoider.new(txn, user: admin, reason: "trying to undo").call
  end

  let(:linked_error) { I18n.t("finance.custody.errors.settlement_linked") }

  it "rejects voiding a settlement's custody debit via the service, leaving custody and the receipt untouched" do
    settlement = settle(source_kind: "employee_custody", amount: "5000")
    debit = settlement.custody_transaction
    expect(account.reload.current_balance).to eq(5_000)
    expect(receipt.reload).to be_settled

    result = direct_void(debit)

    expect(result).not_to be_ok
    expect(result.error).to eq(linked_error)
    expect(debit.reload).not_to be_voided
    expect(account.reload.current_balance).to eq(5_000)
    expect(account.computed_balance).to eq(5_000)
    expect(receipt.reload).to be_settled
    expect(AuditLog.where(auditable: debit, action: "custody_void")).to be_empty
  end

  it "rejects voiding the custody credit of a settlement reversal too" do
    settlement = settle(source_kind: "employee_custody", amount: "5000")
    reverse(settlement)
    credit = settlement.reload.reversal.custody_transaction

    expect(direct_void(credit).error).to eq(linked_error)
    expect(credit.reload).not_to be_voided
    expect(account.reload.current_balance).to eq(10_000)
  end

  it "blocks the void at the model level for any other code path (backstop)" do
    debit = settle(source_kind: "employee_custody", amount: "2000").custody_transaction

    expect { debit.update!(voided_at: Time.current, voided_by: admin, void_reason: "console") }
      .to raise_error(ActiveRecord::RecordInvalid, /#{Regexp.escape(linked_error)}/)
    expect(debit.reload).not_to be_voided
  end

  it "shows the Arabic message when the locale is Arabic" do
    debit = settle(source_kind: "employee_custody", amount: "2000").custody_transaction

    I18n.with_locale(:ar) do
      expect(direct_void(debit).error)
        .to eq("لا يمكن إلغاء حركة العهدة مباشرة لأنها مرتبطة بتسوية مالية. استخدم عكس التسوية من إذن الاستلام.")
    end
  end

  it "still lets normal (non-settlement) custody transactions be voided" do
    adjustment = account.custody_transactions.create!(business: business, txn_type: "adjustment", amount: -300)
    account.refresh_balance!

    result = direct_void(adjustment)

    expect(result).to be_ok
    expect(adjustment.reload).to be_voided
    expect(account.reload.current_balance).to eq(10_000)
  end

  describe "the correct path: reverse the settlement" do
    it "restores custody, reopens the receipt, keeps the original as reversed, and cannot run twice" do
      settlement = settle(source_kind: "employee_custody", amount: "5000")
      direct_void(settlement.custody_transaction) # rejected attempt changes nothing

      expect(reverse(settlement)).to be_ok

      expect(account.reload.current_balance).to eq(10_000)
      receipt.reload
      expect(receipt.total_settled_amount).to eq(0)
      expect(receipt.remaining_settlement_amount).to eq(5_000)
      expect(receipt).to be_pending_settlement
      expect(settlement.reload).to be_reversed
      expect(settlement.amount).to eq(5_000)

      again = reverse(settlement)
      expect(again).not_to be_ok
      expect(account.reload.current_balance).to eq(10_000)
      expect(account.custody_transactions.of_type("inventory_purchase_reversal").count).to eq(1)
    end

    it "reverses settlements independently: A (2,000 custody) reversed, B (3,000 cash) untouched" do
      a = settle(source_kind: "employee_custody", amount: "2000")
      b = settle(source_kind: "company_cash", amount: "3000")
      expect(account.reload.current_balance).to eq(8_000)

      expect(reverse(a)).to be_ok

      expect(account.reload.current_balance).to eq(10_000)
      receipt.reload
      expect(receipt.remaining_settlement_amount).to eq(2_000)
      expect(receipt).to be_partially_settled
      expect(b.reload).not_to be_reversed
      expect(receipt.total_settled_amount).to eq(3_000)
    end

    it "voiding the receipt afterwards reverses only what is still in effect — no duplicate custody credit" do
      a = settle(source_kind: "employee_custody", amount: "2000")
      settle(source_kind: "company_cash", amount: "3000")
      reverse(a)

      result = Inventory::GoodsReceiptVoider.new(goods_receipt_id: receipt.id, actor: admin, reason: "dup").call

      expect(result).to be_ok
      credits = account.custody_transactions.of_type("inventory_purchase_reversal")
      expect(credits.count).to eq(1)
      expect(credits.pluck(:amount)).to all(be_positive)
      expect(account.reload.current_balance).to eq(10_000)
      expect(receipt.reload.total_settled_amount).to eq(0)
      expect(receipt.financial_settlements.count).to eq(4) # 2 originals + 1 reversal each
    end

    it "voiding a receipt with an unreversed custody settlement credits custody exactly once, via a linked credit" do
      a = settle(source_kind: "employee_custody", amount: "2000")

      Inventory::GoodsReceiptVoider.new(goods_receipt_id: receipt.id, actor: admin, reason: "dup").call

      credit = account.custody_transactions.of_type("inventory_purchase_reversal").sole
      expect(credit.amount).to eq(2_000)
      expect(credit.financial_settlement).to eq(a.reload.reversal)
      expect(account.reload.current_balance).to eq(10_000)
      expect(direct_void(credit).error).to eq(linked_error)
    end
  end
end
