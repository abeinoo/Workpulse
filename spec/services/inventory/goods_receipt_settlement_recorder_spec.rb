require "rails_helper"

RSpec.describe Inventory::GoodsReceiptSettlementRecorder, type: :model do
  let(:business)  { create(:business) }
  let(:actor)     { create(:user, :super_admin, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:supplier)  { business.suppliers.create!(name: "Acme Supplies") }
  let(:product) do
    business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0)
  end
  # Employee Custody is always the ACTOR's own custody account.
  let(:account)  { create(:custody_account, business: business, user: actor) }
  let(:employee) { create(:user, business: business) }                      # someone else
  let(:other_account) { create(:custody_account, business: business, user: employee) }

  def top_up!(acct, amount)
    acct.custody_transactions.create!(business: acct.business, txn_type: "top_up", amount: amount)
    acct.refresh_balance!
  end

  # 100 × 50 = 5,000, funded on Supplier Credit and approved through the real approval service.
  def approved_credit_receipt(qty: 100, cost: 50)
    r = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current,
                                      funding_source_kind: "supplier_credit")
    r.items.build(product: product, quantity: qty, unit_cost: cost)
    r.save!
    r.update_column(:approval_status, "pending_approval")
    Inventory::GoodsReceiptApproval.new(goods_receipt_id: r.id, actor: actor).approve!
    r.reload
  end

  def settle(receipt, **params)
    described_class.new(receipt.id, actor: actor, params: params).call
  end

  it "starts a Supplier Credit receipt as pending settlement with nothing paid" do
    receipt = approved_credit_receipt
    expect(receipt).to be_approval_approved
    expect(receipt).to be_pending_settlement
    expect(receipt.financial_settlements).to be_empty
    expect(receipt.remaining_settlement_amount).to eq(5_000)
  end

  describe "company cash" do
    it "fully settles 5,000 → 0 remaining, with no linked account and no custody movement" do
      receipt = approved_credit_receipt

      result = settle(receipt, source_kind: "company_cash", amount: "5000", reference: "CV-001")

      expect(result).to be_ok
      settlement = result.settlement
      expect(settlement.source_kind).to eq("company_cash")
      expect(settlement.funding_source).to be_nil
      expect(settlement.custody_transaction).to be_nil
      expect(settlement.reference).to eq("CV-001")
      expect(settlement.created_by).to eq(actor)
      expect(receipt.reload).to be_settled
      expect(receipt.remaining_settlement_amount).to eq(0)
      expect(CustodyTransaction.where(business: business)).to be_empty
    end
  end

  describe "bank account" do
    it "records a bank payment with its reference and no internal balance movement" do
      receipt = approved_credit_receipt

      result = settle(receipt, source_kind: "bank_account", amount: "1500", reference: "TRX-99")

      expect(result).to be_ok
      expect(result.settlement.source_kind).to eq("bank_account")
      expect(result.settlement.funding_source).to be_nil
      expect(result.settlement.reference).to eq("TRX-99")
      expect(receipt.reload).to be_partially_settled
      expect(CustodyTransaction.where(business: business)).to be_empty
    end
  end

  describe "employee custody (the actor's own)" do
    it "fully settles from the actor's own custody and debits it by 5,000" do
      top_up!(account, 7_000)
      receipt = approved_credit_receipt

      result = settle(receipt, source_kind: "employee_custody", amount: "5000")

      expect(result).to be_ok
      expect(result.settlement.funding_source).to eq(account)
      expect(result.settlement.source_kind).to eq("employee_custody")
      expect(account.reload.current_balance).to eq(2_000)
      expect(account.computed_balance).to eq(2_000)
      expect(receipt.reload).to be_settled

      txn = account.custody_transactions.of_type("inventory_purchase").sole
      expect(txn.amount).to eq(-5_000)
      expect(txn.source).to eq(receipt)
      expect(txn.created_by).to eq(actor)
      expect(txn.notes).to include(receipt.receipt_number, "##{result.settlement.id}")
      # Direct, deterministic link: settlement ↔ the exact custody movement it created.
      expect(txn.financial_settlement).to eq(result.settlement)
      expect(result.settlement.reload.custody_transaction).to eq(txn)
    end

    it "ignores any custody_account_id in the params — another employee's custody can never be debited" do
      top_up!(account, 7_000)
      top_up!(other_account, 9_000)
      receipt = approved_credit_receipt

      result = settle(receipt, source_kind: "employee_custody", custody_account_id: other_account.id, amount: "2000")

      expect(result).to be_ok
      expect(result.settlement.funding_source).to eq(account)
      expect(account.reload.current_balance).to eq(5_000)
      expect(other_account.reload.current_balance).to eq(9_000)
      expect(other_account.custody_transactions.of_type("inventory_purchase")).to be_empty
    end

    it "supports a partial payment from custody" do
      top_up!(account, 7_000)
      receipt = approved_credit_receipt

      result = settle(receipt, source_kind: "employee_custody", amount: "2000")

      expect(result).to be_ok
      expect(account.reload.current_balance).to eq(5_000)
      expect(receipt.reload).to be_partially_settled
      expect(receipt.remaining_settlement_amount).to eq(3_000)
    end

    it "accepts an amount exactly equal to the actor's balance" do
      top_up!(account, 2_000)
      receipt = approved_credit_receipt

      expect(settle(receipt, source_kind: "employee_custody", amount: "2000")).to be_ok
      expect(account.reload.current_balance).to eq(0)
    end

    describe "custody balance is an accounting balance, not a spending limit" do
      it "10,000 − 5,000 → 5,000" do
        top_up!(account, 10_000)

        expect(settle(approved_credit_receipt, source_kind: "employee_custody", amount: "5000")).to be_ok
        expect(account.reload.current_balance).to eq(5_000)
      end

      it "1,000 − 2,000 → −1,000: succeeds, full -2,000 transaction, no clamping" do
        top_up!(account, 1_000)
        receipt = approved_credit_receipt

        result = settle(receipt, source_kind: "employee_custody", amount: "2000")

        expect(result).to be_ok
        expect(result.settlement.custody_transaction.amount).to eq(-2_000)
        expect(account.reload.current_balance).to eq(-1_000)
        expect(account.computed_balance).to eq(-1_000)
        expect(receipt.reload.total_settled_amount).to eq(2_000)
      end

      it "0 − 500 → −500" do
        account # exists with no transactions

        expect(settle(approved_credit_receipt, source_kind: "employee_custody", amount: "500")).to be_ok
        expect(account.reload.current_balance).to eq(-500)
      end

      it "a negative balance keeps working: −2,000 → another payment → a top-up brings it back up" do
        top_up!(account, 10_000)
        receipt = approved_credit_receipt(qty: 300, cost: 50) # 15,000

        expect(settle(receipt, source_kind: "employee_custody", amount: "12000")).to be_ok
        expect(account.reload.current_balance).to eq(-2_000)

        expect(settle(receipt, source_kind: "employee_custody", amount: "1000")).to be_ok # from negative
        expect(account.reload.current_balance).to eq(-3_000)

        top_up!(account, 5_000)
        expect(account.reload.current_balance).to eq(2_000)
        expect(account.computed_balance).to eq(2_000)
      end

      it "reversing a payment that went negative restores the FULL amount (−1,000 → 1,000)" do
        top_up!(account, 1_000)
        receipt = approved_credit_receipt
        settlement = settle(receipt, source_kind: "employee_custody", amount: "2000").settlement
        expect(account.reload.current_balance).to eq(-1_000)

        result = Inventory::GoodsReceiptSettlementReverser.new(goods_receipt_id: receipt.id, settlement_id: settlement.id,
                                                               actor: actor, reason: "Mistake").call

        expect(result).to be_ok
        expect(account.reload.current_balance).to eq(1_000)
        expect(settlement.reload.reversal.custody_transaction.amount).to eq(2_000)
      end
    end

    it "rejects when the actor's custody account is inactive" do
      top_up!(account, 7_000)
      account.update!(active: false)
      receipt = approved_credit_receipt

      result = settle(receipt, source_kind: "employee_custody", amount: "100")

      expect(result).not_to be_ok
      expect(result.error).to eq(I18n.t("inventory.goods_receipts.settlements.errors.no_custody_account"))
      expect(receipt.financial_settlements.count).to eq(0)
    end

    it "rejects an actor with no custody account, even if another employee's id is submitted" do
      top_up!(other_account, 9_000)
      receipt = approved_credit_receipt

      result = settle(receipt, source_kind: "employee_custody", custody_account_id: other_account.id, amount: "100")

      expect(result).not_to be_ok
      expect(result.error).to eq(I18n.t("inventory.goods_receipts.settlements.errors.no_custody_account"))
      expect(other_account.reload.current_balance).to eq(9_000)
      expect(receipt.financial_settlements.count).to eq(0)
    end
  end

  describe "partial payments" do
    it "5,000 → pay 2,000 → 3,000 remaining (partially settled) → pay 3,000 → settled" do
      receipt = approved_credit_receipt

      expect(settle(receipt, source_kind: "company_cash", amount: "2000")).to be_ok
      receipt.reload
      expect(receipt.total_settled_amount).to eq(2_000)
      expect(receipt.remaining_settlement_amount).to eq(3_000)
      expect(receipt).to be_partially_settled

      expect(settle(receipt, source_kind: "bank_account", amount: "3000")).to be_ok
      receipt.reload
      expect(receipt.remaining_settlement_amount).to eq(0)
      expect(receipt).to be_settled
      expect(receipt.financial_settlements.count).to eq(2)
    end
  end

  describe "guards" do
    it "rejects paying more than the remaining amount" do
      receipt = approved_credit_receipt
      settle(receipt, source_kind: "company_cash", amount: "2000")

      result = settle(receipt, source_kind: "company_cash", amount: "3000.01")

      expect(result).not_to be_ok
      expect(result.error).to include("3,000.00")
      expect(receipt.reload.total_settled_amount).to eq(2_000)
    end

    it "rejects any payment once the receipt is fully settled" do
      receipt = approved_credit_receipt
      settle(receipt, source_kind: "company_cash", amount: "5000")

      result = settle(receipt, source_kind: "company_cash", amount: "1")

      expect(result).not_to be_ok
      expect(result.error).to eq(I18n.t("inventory.goods_receipts.settlements.errors.already_settled"))
    end

    it "rejects zero/negative/garbage amounts and unknown sources" do
      receipt = approved_credit_receipt

      expect(settle(receipt, source_kind: "company_cash", amount: "0")).not_to be_ok
      expect(settle(receipt, source_kind: "company_cash", amount: "-5")).not_to be_ok
      expect(settle(receipt, source_kind: "company_cash", amount: "abc")).not_to be_ok
      expect(settle(receipt, source_kind: "supplier_credit", amount: "10")).not_to be_ok
      expect(receipt.financial_settlements.count).to eq(0)
    end

    it "rejects a receipt that is not approved" do
      r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current, funding_source_kind: "supplier_credit")
      r.items.build(product: product, quantity: 1, unit_cost: 10)
      r.save!

      result = settle(r, source_kind: "company_cash", amount: "10")

      expect(result).not_to be_ok
      expect(result.error).to eq(I18n.t("inventory.goods_receipts.settlements.errors.not_settleable"))
    end

    it "rejects a voided receipt" do
      receipt = approved_credit_receipt
      Inventory::GoodsReceiptVoider.new(goods_receipt_id: receipt.id, actor: actor, reason: "dup").call

      result = settle(receipt, source_kind: "company_cash", amount: "10")

      expect(result).not_to be_ok
      expect(receipt.financial_settlements.count).to eq(0)
    end
  end

  describe "receipt lifecycle independence" do
    it "never changes approval/receiving status, stock, or the receipt amount" do
      receipt = approved_credit_receipt
      Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: receipt.id, actor: actor).call
      receipt.reload
      stock_before = product.reload.current_stock

      settle(receipt, source_kind: "company_cash", amount: "2000")
      receipt.reload

      expect(receipt).to be_approval_approved
      expect(receipt).to be_confirmed
      expect(receipt.total_value).to eq(5_000)
      expect(product.reload.current_stock).to eq(stock_before)
      expect(InventoryMovement.where(source: receipt).count).to eq(1)
    end

    it "can settle an approved receipt whose goods have not been received yet" do
      receipt = approved_credit_receipt
      expect(receipt).to be_draft # approved, not yet received

      expect(settle(receipt, source_kind: "company_cash", amount: "5000")).to be_ok
      expect(receipt.reload).to be_draft
      expect(receipt).to be_settled
    end
  end

  it "writes an audit event with who, how much, source, employee, and supplier" do
    top_up!(account, 7_000)
    receipt = approved_credit_receipt

    result = settle(receipt, source_kind: "employee_custody", amount: "2000", reference: "R-1")

    log = AuditLog.for_auditable(receipt).find_by(action: "record_settlement")
    expect(log.actor).to eq(actor)
    expect(log.metadata).to include(
      "settlement_id" => result.settlement.id, "source_kind" => "employee_custody",
      "custody_account_id" => account.id, "employee_id" => actor.id,
      "supplier_id" => supplier.id, "reference" => "R-1"
    )
    expect(log.metadata["amount"].to_d).to eq(2_000)
  end
end
