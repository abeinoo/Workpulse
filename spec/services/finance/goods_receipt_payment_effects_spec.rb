require "rails_helper"

# Batch S M3 — Finance::GoodsReceiptPaymentEffects, the Finance & Sales
# implementation of Inventory::GoodsReceiptPaymentEffects. Every operation is
# called through the contract (so its result checks apply) and its rows are
# compared with the fields the M1 characterization pins for the Inventory services
# (spec/characterization/inventory_purchasing/goods_receipt_payments_spec.rb).
RSpec.describe Finance::GoodsReceiptPaymentEffects, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:contract)  { Inventory::GoodsReceiptPaymentEffects }
  let(:now)       { Time.zone.local(2026, 10, 21, 10, 0, 0) }
  let(:business)  { create(:business) }
  let(:requester) { create(:user, business: business) }
  let(:actor)     { create(:user, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 0, average_cost_price: 0) }
  let(:custody)   { funded(requester, 1000) }

  around { |example| travel_to(now) { example.run } }

  def funded(user, amount)
    create(:custody_account, business: business, user: user).tap do |account|
      account.custody_transactions.create!(business: business, txn_type: "top_up", amount: amount)
      account.refresh_balance!
    end
  end

  def receipt(kind: "employee_custody", account: custody)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current, created_by: requester,
                                      funding_source_kind: kind, funding_source: (account if kind == "employee_custody"))
    r.items.build(product: product, quantity: 2, unit_cost: 125)
    r.save!
    r
  end

  def settlements(r) = FinancialSettlement.where(settleable: r).order(:id).to_a
  def txns(account) = CustodyTransaction.where(custody_account: account).where.not(txn_type: "top_up").order(:id).to_a
  def balance(account) = account.reload.current_balance

  it "is the registered handler" do
    expect(contract.handler).to equal(described_class)
  end

  describe "custody_account_active?" do
    it "true for an active custody account, false for an inactive one or none" do
      expect(contract.custody_account_active?(receipt: receipt)).to be(true)
      custody.update!(active: false)
      expect(contract.custody_account_active?(receipt: receipt.reload)).to be(false)
      expect(contract.custody_account_active?(receipt: receipt(kind: "company_cash"))).to be(false)
    end
  end

  describe "approval_payment" do
    it "employee custody: locks the account, one settlement, a linked debit, the balance" do
      r = receipt
      expect(custody).to receive(:lock!).and_call_original
      allow(r).to receive(:funding_source).and_return(custody)
      contract.approval_payment(receipt: r, amount: 250, actor: actor)

      settlement = settlements(r).sole
      expect(settlement).to have_attributes(funding_source: custody, source_kind: "employee_custody", reference: nil,
                                            amount: 250, settled_at: now, created_by_id: actor.id,
                                            notes: "Inventory Purchase - Goods Receipt #{r.receipt_number}")
      expect(txns(custody).map { [ _1.txn_type, _1.amount, _1.source, _1.financial_settlement_id, _1.created_by_id, _1.notes ] })
        .to eq([ [ "inventory_purchase", -250, r, settlement.id, actor.id, "Inventory Purchase - Goods Receipt #{r.receipt_number}" ] ])
      expect(balance(custody)).to eq(750)
    end

    %w[company_cash bank_account].each do |kind|
      it "#{kind}: one accountless settlement referencing the receipt number" do
        r = receipt(kind: kind)
        contract.approval_payment(receipt: r, amount: 250, actor: actor)
        expect(settlements(r).sole).to have_attributes(funding_source_id: nil, source_kind: kind, reference: r.receipt_number,
                                                       amount: 250, notes: "Inventory Purchase - Goods Receipt #{r.receipt_number}")
      end
    end

    it "nothing for supplier credit or a zero amount" do
      [ [ receipt(kind: "supplier_credit"), 250 ], [ receipt, 0 ], [ receipt(kind: "company_cash"), 0 ] ].each do |r, amount|
        expect(contract.approval_payment(receipt: r, amount: amount, actor: actor)).to be_nil
        expect(settlements(r)).to be_empty
      end
      expect(txns(custody)).to be_empty
    end
  end

  describe "advance_applied" do
    it "one application settlement funded by the advance; no money moves" do
      request = PurchaseRequest.new(business: business, created_by: requester)
      request.items.build(product: product, quantity: 2, unit_price: 125, source_warehouse: warehouse)
      request.save!
      request.update_column(:status, "approved")
      recorded = Inventory::PurchaseRequestAdvanceRecorder.new(
        purchase_request_id: request.id, actor: create(:user, :super_admin, business: business), idempotency_key: nil,
        params: { amount: 100, source_kind: "company_cash", paid_on: Date.current, reference: "DEP-1", notes: "d" }
      ).call
      Inventory::PurchaseRequestAdvanceWorkflow.new(advance_id: recorded.advance.id, actor: actor).confirm!
      r = receipt(kind: "supplier_credit")

      contract.advance_applied(receipt: r, advance: recorded.advance, amount: 100, actor: actor, reference: "PR-1", notes: "applied")
      expect(settlements(r).sole).to have_attributes(funding_source: recorded.advance, source_kind: "purchase_request_advance",
                                                     reference: "PR-1", amount: 100, notes: "applied", created_by_id: actor.id)
    end
  end

  describe "payment_source_kind? and payer_custody_account_id" do
    it "accepts the payment kinds only" do
      expect(%w[employee_custody company_cash bank_account supplier_credit purchase_request_advance x]
               .map { contract.payment_source_kind?(_1) }).to eq([ true, true, true, false, false, false ])
    end

    it "is the actor's own active custody account, or nil" do
      own = funded(actor, 10)
      expect(contract.payer_custody_account_id(actor: actor)).to eq(own.id)
      own.update!(active: false)
      expect(contract.payer_custody_account_id(actor: actor)).to be_nil
      expect(contract.payer_custody_account_id(actor: create(:user, business: business))).to be_nil
    end
  end

  describe "record_settlement" do
    let(:r) { receipt(kind: "supplier_credit") }

    it "custody: locks the account, a settlement, a linked debit, the balance; returns the Payment" do
      own = funded(actor, 300)
      payment = contract.record_settlement(receipt: r, actor: actor, source_kind: "employee_custody", custody_account_id: own.id,
                                           amount: 80, reference: "INV-9", notes: "part", settled_at: Date.new(2026, 10, 20))
      settlement = settlements(r).sole
      expect(payment.to_h).to eq(settlement: settlement, settlement_id: settlement.id, reference: "INV-9",
                                 custody_account_id: own.id, employee_id: actor.id)
      expect(settlement).to have_attributes(funding_source: own, source_kind: "employee_custody", amount: 80, notes: "part",
                                            settled_at: Date.new(2026, 10, 20).in_time_zone)
      expect(txns(own).map { [ _1.txn_type, _1.amount, _1.financial_settlement_id, _1.notes ] })
        .to eq([ [ "inventory_purchase", -80, settlement.id, "Goods Receipt #{r.receipt_number} - Settlement ##{settlement.id}" ] ])
      expect(balance(own)).to eq(220)
    end

    it "accountless: the settlement only; the Payment has no account" do
      payment = contract.record_settlement(receipt: r, actor: actor, source_kind: "company_cash", custody_account_id: nil,
                                           amount: 50, reference: nil, notes: nil, settled_at: now)
      expect(payment.to_h.except(:settlement)).to eq(settlement_id: settlements(r).sole.id, reference: nil,
                                                     custody_account_id: nil, employee_id: nil)
      expect(CustodyTransaction.where(source: r)).to be_empty
    end
  end

  describe "reverse_settlement" do
    let(:own) { funded(actor, 300) }
    let(:r)   { receipt(kind: "supplier_credit") }

    def pay(kind, amount)
      contract.record_settlement(receipt: r, actor: actor, source_kind: kind, custody_account_id: (own.id if kind == "employee_custody"),
                                 amount: amount, reference: "INV-9", notes: nil, settled_at: now).settlement
    end

    it "custody payment: the reversal, a linked credit, the balance restored; returns the Reversal" do
      original = pay("employee_custody", 80)
      result = contract.reverse_settlement(receipt: r, settlement_id: original.id, actor: actor, reason: "wrong")

      reversal = settlements(r).last
      expect(result.to_h).to eq(status: :reversed, settlement: reversal, settlement_id: original.id, reversal_id: reversal.id,
                                amount: 80, source_kind: "employee_custody", funding_source_id: own.id)
      expect(reversal).to have_attributes(amount: -80, reverses_settlement_id: original.id, notes: "wrong", reference: "INV-9")
      expect(txns(own).last).to have_attributes(txn_type: "inventory_purchase_reversal", amount: 80, financial_settlement_id: reversal.id,
                                                notes: "Goods Receipt #{r.receipt_number} - Settlement ##{original.id} reversed: wrong")
      expect(balance(own)).to eq(300)
    end

    it "refuses a reversed original or a reversal row (:already_reversed), writing nothing" do
      original = pay("company_cash", 50)
      contract.reverse_settlement(receipt: r, settlement_id: original.id, actor: actor, reason: "x")
      reversal = settlements(r).last
      count = settlements(r).size

      [ original, reversal ].each do |s|
        expect(contract.reverse_settlement(receipt: r, settlement_id: s.id, actor: actor, reason: "x").status).to eq(:already_reversed)
      end
      expect(settlements(r).size).to eq(count)
    end

    it "a settlement of another receipt is not found" do
      other = pay("company_cash", 50)
      expect { contract.reverse_settlement(receipt: receipt, settlement_id: other.id, actor: actor, reason: "x") }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "reverse_all" do
    it "reverses every settlement still in effect, crediting custody for each custody payment" do
      own = funded(actor, 300)
      r = receipt(kind: "supplier_credit")
      custody_paid = contract.record_settlement(receipt: r, actor: actor, source_kind: "employee_custody", custody_account_id: own.id,
                                                amount: 80, reference: nil, notes: nil, settled_at: now).settlement
      contract.record_settlement(receipt: r, actor: actor, source_kind: "company_cash", custody_account_id: nil,
                                 amount: 50, reference: "C-1", notes: nil, settled_at: now)

      expect(contract.reverse_all(receipt: r, actor: actor, notes: "void note")).to be_nil
      reversals = settlements(r).select(&:reversal?)
      expect(reversals.map { [ _1.amount, _1.notes ] }).to contain_exactly([ -80, "void note" ], [ -50, "void note" ])
      credit = txns(own).last
      expect(credit).to have_attributes(txn_type: "inventory_purchase_reversal", amount: 80,
                                        financial_settlement_id: reversals.find { _1.reverses_settlement_id == custody_paid.id }.id,
                                        notes: "Goods Receipt Cancellation - #{r.receipt_number}")
      expect(balance(own)).to eq(300)
      expect(contract.reverse_all(receipt: r, actor: actor, notes: "again")).to be_nil
      expect(settlements(r).size).to eq(4)
    end
  end
end
