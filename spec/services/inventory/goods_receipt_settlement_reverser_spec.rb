require "rails_helper"

RSpec.describe Inventory::GoodsReceiptSettlementReverser, type: :model do
  let(:business)  { create(:business) }
  let(:actor)     { create(:user, :super_admin, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product) do
    business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0)
  end
  # Employee Custody is always the recording actor's own account.
  let(:account_a)  { create(:custody_account, business: business, user: actor) }

  def top_up!(acct, amount)
    acct.custody_transactions.create!(business: business, txn_type: "top_up", amount: amount)
    acct.refresh_balance!
  end

  def approved_credit_receipt(qty: 100, cost: 50)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current,
                                      funding_source_kind: "supplier_credit")
    r.items.build(product: product, quantity: qty, unit_cost: cost)
    r.save!
    r.update_column(:approval_status, "pending_approval")
    Inventory::GoodsReceiptApproval.new(goods_receipt_id: r.id, actor: actor).approve!
    r.reload
  end

  def settle(receipt, **params)
    result = Inventory::GoodsReceiptSettlementRecorder.new(receipt.id, actor: actor, params: params).call
    raise "settle failed: #{result.error}" unless result.ok?

    result.settlement
  end

  def reverse(receipt, settlement, reason: "Recorded from the wrong custody")
    described_class.new(goods_receipt_id: receipt.id, settlement_id: settlement.id, actor: actor, reason: reason).call
  end

  def void(receipt, reason: "Wrong supplier")
    Inventory::GoodsReceiptVoider.new(goods_receipt_id: receipt.id, actor: actor, reason: reason).call
  end

  it "reverses a 5,000 custody settlement: original kept & marked reversed, custody +5,000, remaining back to 5,000" do
    top_up!(account_a, 7_000)
    receipt  = approved_credit_receipt
    original = settle(receipt, source_kind: "employee_custody", amount: "5000")
    expect(account_a.reload.current_balance).to eq(2_000)

    result = reverse(receipt, original)

    expect(result).to be_ok
    original.reload
    expect(original.amount).to eq(5_000) # untouched
    expect(original).to be_reversed
    reversal = original.reversal
    expect(reversal.amount).to eq(-5_000)
    expect(reversal.notes).to eq("Recorded from the wrong custody")
    expect(reversal.created_by).to eq(actor)
    expect(reversal.source_kind).to eq("employee_custody")

    expect(account_a.reload.current_balance).to eq(7_000)
    credit = account_a.custody_transactions.of_type("inventory_purchase_reversal").sole
    expect(credit.amount).to eq(5_000)
    expect(credit.source).to eq(receipt)
    expect(credit.financial_settlement).to eq(reversal)          # credit ↔ reversal row
    expect(original.custody_transaction.amount).to eq(-5_000)    # debit ↔ original row

    receipt.reload
    expect(receipt.remaining_settlement_amount).to eq(5_000)
    expect(receipt).to be_pending_settlement

    log = AuditLog.for_auditable(receipt).find_by(action: "reverse_settlement")
    expect(log.actor).to eq(actor)
    expect(log.metadata).to include("settlement_id" => original.id, "reversal_id" => reversal.id,
                                    "reason" => "Recorded from the wrong custody")
  end

  it "requires a reason" do
    receipt  = approved_credit_receipt
    original = settle(receipt, source_kind: "company_cash", amount: "1000")

    result = reverse(receipt, original, reason: "  ")

    expect(result).not_to be_ok
    expect(result.error).to eq(I18n.t("inventory.goods_receipts.settlements.errors.reason_required"))
    expect(original.reload).not_to be_reversed
  end

  it "refuses to reverse a reversal row" do
    receipt  = approved_credit_receipt
    original = settle(receipt, source_kind: "company_cash", amount: "1000")
    reversal = reverse(receipt, original).settlement

    result = reverse(receipt, reversal)

    expect(result).not_to be_ok
    expect(receipt.financial_settlements.count).to eq(2)
  end

  it "refuses to reverse a settlement belonging to another receipt" do
    receipt_1 = approved_credit_receipt
    receipt_2 = approved_credit_receipt
    other     = settle(receipt_2, source_kind: "company_cash", amount: "100")

    expect { reverse(receipt_1, other) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "can reverse the approval-time custody settlement of an employee-custody-funded receipt" do
    top_up!(account_a, 1_000)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current,
                                      funding_source_kind: "employee_custody", funding_source: account_a)
    r.items.build(product: product, quantity: 10, unit_cost: 50)
    r.save!
    r.update_column(:approval_status, "pending_approval")
    Inventory::GoodsReceiptApproval.new(goods_receipt_id: r.id, actor: actor).approve!
    r.reload
    expect(account_a.reload.current_balance).to eq(500)

    approval_settlement = r.financial_settlements.sole
    expect(approval_settlement.custody_transaction.amount).to eq(-500) # approval-time debit is linked too

    expect(reverse(r, approval_settlement)).to be_ok

    expect(account_a.reload.current_balance).to eq(1_000)
    expect(r.reload).to be_pending_settlement
  end

  describe "mixed-source scenario: 5,000 = A 2,000 custody (Employee A) + B 3,000 company cash" do
    let!(:receipt) { top_up!(account_a, 2_500); approved_credit_receipt }
    let!(:settlement_a) { settle(receipt, source_kind: "employee_custody", amount: "2000") }
    let!(:settlement_b) { settle(receipt, source_kind: "company_cash", amount: "3000", reference: "CV-7") }

    it "runs the full reverse → re-reverse → void sequence safely" do
      # 1. fully settled
      expect(receipt.reload).to be_settled
      expect(account_a.reload.current_balance).to eq(500)

      # 2. reverse A
      expect(reverse(receipt, settlement_a)).to be_ok

      # 3. Employee A gets the 2,000 back
      expect(account_a.reload.current_balance).to eq(2_500)

      # 4. remaining 2,000 / 5. partially settled
      receipt.reload
      expect(receipt.remaining_settlement_amount).to eq(2_000)
      expect(receipt).to be_partially_settled

      # 6. B still valid
      expect(settlement_b.reload).not_to be_reversed
      expect(receipt.total_settled_amount).to eq(3_000)

      # 7. reversing A again is rejected, writes nothing
      again = reverse(receipt, settlement_a)
      expect(again).not_to be_ok
      expect(again.error).to eq(I18n.t("financial_settlements.errors.already_reversed"))
      expect(receipt.financial_settlements.count).to eq(3)
      expect(account_a.custody_transactions.of_type("inventory_purchase_reversal").count).to eq(1)

      # 8. void the whole receipt → only B (still in effect) is reversed
      expect(void(receipt)).to be_ok
      receipt.reload
      expect(receipt).to be_voided
      expect(receipt.total_settled_amount).to eq(0)
      expect(receipt).to be_pending_settlement
      expect(settlement_b.reload).to be_reversed
      expect(settlement_b.reversal.amount).to eq(-3_000)
      expect(settlement_b.reversal.source_kind).to eq("company_cash")

      # 9. no invalid/negative custody reversal, balance unchanged by the void (A was already refunded)
      reversals = account_a.custody_transactions.of_type("inventory_purchase_reversal")
      expect(reversals.count).to eq(1)
      expect(reversals.pluck(:amount)).to all(be_positive)
      expect(account_a.reload.current_balance).to eq(2_500)
      expect(account_a.computed_balance).to eq(2_500)

      # every custody movement is linked to exactly one settlement, and vice versa
      linked = receipt.financial_settlements.includes(:custody_transaction).to_a
      linked.select { |s| s.source_kind == "employee_custody" }.each do |s|
        expect(s.custody_transaction).to be_present
        expect(s.custody_transaction.amount).to eq(-s.amount)
      end
      expect(linked.select { |s| s.source_kind == "company_cash" }.map(&:custody_transaction)).to all(be_nil)
      expect(account_a.custody_transactions.where(financial_settlement_id: nil)
                      .of_type(%w[inventory_purchase inventory_purchase_reversal])).to be_empty

      # 10. no duplicated settlements: 2 originals + exactly 1 reversal each
      rows = receipt.financial_settlements.to_a
      expect(rows.size).to eq(4)
      expect(rows.count(&:reversal?)).to eq(2)
      expect(rows.map(&:reverses_settlement_id).compact).to contain_exactly(settlement_a.id, settlement_b.id)
    end

    it "voiding without prior reversals reverses both settlements and refunds only the custody one" do
      expect(void(receipt)).to be_ok

      receipt.reload
      expect(receipt.total_settled_amount).to eq(0)
      expect(settlement_a.reload).to be_reversed
      expect(settlement_b.reload).to be_reversed
      expect(account_a.reload.current_balance).to eq(2_500)
      credit = account_a.custody_transactions.of_type("inventory_purchase_reversal").sole
      expect(credit.amount).to eq(2_000)
      expect(credit.financial_settlement).to eq(settlement_a.reload.reversal)
    end

    it "refuses reversal on a voided receipt" do
      void(receipt)

      result = reverse(receipt, settlement_a)

      expect(result).not_to be_ok
      expect(result.error).to eq(I18n.t("inventory.goods_receipts.settlements.errors.receipt_voided"))
    end
  end

  describe FinancialSettlementService do
    it "reverse_all is idempotent — a second call reverses nothing" do
      receipt = approved_credit_receipt
      settle(receipt, source_kind: "company_cash", amount: "1000")
      settle(receipt, source_kind: "bank_account", amount: "500")

      first  = described_class.reverse_all(settleable: receipt, actor: actor)
      second = described_class.reverse_all(settleable: receipt, actor: actor)

      expect(first.size).to eq(2)
      expect(first).to all(be_ok)
      expect(second).to be_empty
      expect(receipt.reload.total_settled_amount).to eq(0)
    end

    it "the unique index blocks a second reversal row even if the service guard is bypassed" do
      receipt  = approved_credit_receipt
      original = settle(receipt, source_kind: "company_cash", amount: "1000")
      described_class.reverse(settlement: original, actor: actor)

      result = described_class.new(settleable: receipt, actor: actor)
                              .create(amount: -1000, source_kind: "company_cash", reverses_settlement: original)

      expect(result).not_to be_ok
      expect(receipt.financial_settlements.count).to eq(2)
    end
  end
end
