require "rails_helper"

# LEGACY advances on a Purchase Request — supplier payments recorded before the
# funding workflow (2026-11-13; no recipient): how receipt approval consumes
# them (full, partial, multiple, oldest first), their cancellation and their
# reversal, which must keep working for historical rows. The application can no
# longer confirm one, so confirmed ones are built in their historical shape by
# #legacy_confirmed_advance (spec/support/purchase_request_advance_helpers.rb).
# Funding advances: purchase_request_advance_funding_spec.rb.
RSpec.describe "Purchase Request legacy advance payments", type: :model do
  let(:business)  { create(:business) }
  let(:requester) { create(:user, business: business, first_name: "Ahmed") }
  let(:recorder)  { create(:user, :super_admin, business: business) }
  let(:confirmer) { create(:user, business: business) }
  let(:approver)  { create(:user, business: business) }
  let(:supplier)  { business.suppliers.create!(name: "Nile Beauty") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product_a) { business.products.create!(name: "Shampoo", sku: "SH-1", average_cost_price: 100) }
  let(:product_b) { business.products.create!(name: "Conditioner", sku: "CO-1", average_cost_price: 42) }

  # Ahmed's custody, funded with 500.
  let(:custody) do
    create(:custody_account, business: business, user: requester, name: "Ahmed Float").tap do |account|
      account.custody_transactions.create!(business: business, txn_type: "top_up", amount: 500)
      account.refresh_balance!
    end
  end

  # 2 × 100 + 1 × 42 = 242
  let(:request) do
    pr = PurchaseRequest.new(business: business, supplier: supplier, created_by: requester,
                         responsible_employee: requester) # pays from their custody
    pr.items.build(product: product_a, quantity: 2, unit_price: 100, source_warehouse: warehouse)
    pr.items.build(product: product_b, quantity: 1, unit_price: 42, source_warehouse: warehouse)
    pr.save!
    pr.update_column(:status, "approved")
    pr
  end

  def workflow(advance, actor: confirmer)
    Inventory::PurchaseRequestAdvanceWorkflow.new(advance_id: advance.id, actor: actor)
  end

  def confirmed_advance(amount, source_kind: "company_cash", account: nil)
    legacy_confirmed_advance(request: request, amount: amount, actor: confirmer, source_kind: source_kind,
                             custody_account: account, reference: "DEP-1").reload
  end

  # A legacy advance recorded but never confirmed (it can now only be cancelled).
  def pending_legacy_advance(amount)
    request.advances.create!(business: business, amount: amount, source_kind: "company_cash", paid_on: Date.current,
                             created_by: recorder)
  end

  # A receipt from the request, submitted and approved by `approver`.
  def approved_receipt(lines, kind: "supplier_credit", account: nil)
    receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, purchase_request: request,
                                            received_on: Date.current, created_by: requester,
                                            funding_source_kind: kind, funding_source: account)
    lines.each do |product, qty, cost|
      receipt.items.build(product: product, quantity: qty, unit_cost: cost,
                          purchase_request_item: request.items.find_by!(product: product))
    end
    receipt.save!
    receipt.update_column(:approval_status, "pending_approval")
    result = Inventory::GoodsReceiptApproval.new(goods_receipt_id: receipt.id, actor: approver).approve!
    expect(result).to be_ok, result.error
    receipt.reload
  end

  def applied_on(receipt) = receipt.financial_settlements.advance_applications.sum(:amount)

  describe "cancellation and reversal" do
    it "a cancelled pending advance never counts" do
      advance = pending_legacy_advance(100)
      expect(workflow(advance).cancel!(reason: "")).not_to be_ok
      expect(workflow(advance).cancel!(reason: "supplier waived deposit")).to be_ok

      expect(advance.reload).to have_attributes(status: "cancelled", cancelled_by_id: confirmer.id,
                                                cancellation_reason: "supplier waived deposit")
      expect(request.reload.amount_remaining_after_advances).to eq(242)
      expect(workflow(advance).cancel!(reason: "again")).not_to be_ok # never twice
    end

    it "reversing a custody advance restores the balance with linked mirror rows, never editing originals" do
      advance  = confirmed_advance(100, source_kind: "employee_custody", account: custody)
      original = advance.financial_settlement

      expect(workflow(advance).reverse!(reason: "wrong supplier")).to be_ok

      advance.reload
      expect(advance).to have_attributes(status: "reversed", reversed_by_id: confirmer.id, reversal_reason: "wrong supplier")
      expect(original.reload.reversal).to have_attributes(amount: -100, funding_source: custody)
      expect(original.reversal.custody_transaction).to have_attributes(txn_type: "inventory_purchase_reversal", amount: 100)
      expect(original.custody_transaction.reload.voided_at).to be_nil
      expect(custody.reload.computed_balance).to eq(500)
      expect(request.reload.advances_total).to eq(0)
      expect(request.amount_remaining_after_advances).to eq(242)
      expect(AuditLog.where(auditable: advance).pluck(:action)).to include("reverse")

      expect(workflow(advance).reverse!(reason: "again")).not_to be_ok
      expect(custody.reload.computed_balance).to eq(500)
    end

    it "refuses to reverse an advance already applied to a receipt — void the receipt first" do
      advance = confirmed_advance(100)
      receipt = approved_receipt([ [ product_a, 2, 100 ], [ product_b, 1, 42 ] ])

      expect(workflow(advance).reverse!(reason: "x").error)
        .to eq(I18n.t("inventory.purchase_request_advances.errors.already_applied"))

      expect(Inventory::GoodsReceiptVoider.new(goods_receipt_id: receipt.id, actor: approver, reason: "wrong").call).to be_ok
      expect(advance.reload.unapplied_amount).to eq(100)
      expect(workflow(advance).reverse!(reason: "refunded")).to be_ok
    end
  end

  describe "receiving" do
    it "full receipt: deducts the advance once; only the remainder is paid" do
      confirmed_advance(100)
      receipt = approved_receipt([ [ product_a, 2, 100 ], [ product_b, 1, 42 ] ], kind: "company_cash")

      expect(receipt.total_value).to eq(242)
      expect(applied_on(receipt)).to eq(100)
      cash = receipt.financial_settlements.where(source_kind: "company_cash").sole
      expect(cash.amount).to eq(142)
      expect(receipt).to be_settled
      expect(request.reload.unapplied_advances_total).to eq(0)
    end

    it "custody-funded receipt: the approver's custody is checked and debited only for the amount due" do
      confirmed_advance(100)
      receipt = approved_receipt([ [ product_a, 2, 100 ], [ product_b, 1, 42 ] ], kind: "employee_custody", account: custody)

      expect(custody.reload.computed_balance).to eq(500 - 142)
      expect(receipt.custody_transactions.sole.amount).to eq(-142)
      expect(receipt).to be_settled
    end

    it "partial receipt: consumes the advance up to the receipt value, never more" do
      confirmed_advance(150)
      first = approved_receipt([ [ product_a, 1, 100 ] ])

      expect(applied_on(first)).to eq(100)
      expect(first.remaining_settlement_amount).to eq(0)
      expect(request.reload.unapplied_advances_total).to eq(50)

      second = approved_receipt([ [ product_a, 1, 100 ], [ product_b, 1, 42 ] ])
      expect(applied_on(second)).to eq(50)
      expect(second.remaining_settlement_amount).to eq(92)
      expect(request.reload.unapplied_advances_total).to eq(0)
    end

    it "multiple partial receipts never consume the same advance twice" do
      # Four receipts of 1 Conditioner each: the line must order 4 — approval
      # never pays for more than can still arrive (GoodsReceiptApproval).
      request.items.find_by!(product: product_b).update_column(:quantity, 4)
      advance = confirmed_advance(100)
      receipts = 3.times.map { approved_receipt([ [ product_b, 1, 42 ] ]) }

      expect(receipts.map { |r| applied_on(r) }).to eq([ 42, 42, 16 ])
      expect(advance.reload.applied_amount).to eq(100)
      expect(advance.unapplied_amount).to eq(0)

      fourth = approved_receipt([ [ product_b, 1, 42 ] ])
      expect(applied_on(fourth)).to eq(0)
      expect(fourth.remaining_settlement_amount).to eq(42)
    end

    it "multiple advances across multiple receipts are applied oldest first" do
      older = confirmed_advance(100, source_kind: "employee_custody", account: custody)
      newer = confirmed_advance(50, source_kind: "company_cash")

      first  = approved_receipt([ [ product_a, 1, 120 ] ])
      second = approved_receipt([ [ product_a, 1, 100 ], [ product_b, 1, 42 ] ])

      expect(first.financial_settlements.advance_applications.map { |s| [ s.funding_source, s.amount ] })
        .to eq([ [ older, 100 ], [ newer, 20 ] ])
      expect(second.financial_settlements.advance_applications.map { |s| [ s.funding_source, s.amount ] })
        .to eq([ [ newer, 30 ] ])
      expect(first.remaining_settlement_amount).to eq(0)
      expect(second.remaining_settlement_amount).to eq(112)
      # Custody was debited once — at advance confirmation — never again by receiving.
      expect(custody.reload.computed_balance).to eq(400)
    end

    it "a cancelled or reversed advance is never applied" do
      cancelled = pending_legacy_advance(60)
      workflow(cancelled).cancel!(reason: "no")
      reversed = confirmed_advance(40)
      workflow(reversed).reverse!(reason: "refund")

      receipt = approved_receipt([ [ product_b, 1, 42 ] ])
      expect(applied_on(receipt)).to eq(0)
      expect(receipt.remaining_settlement_amount).to eq(42)
    end

    it "voiding a receipt releases its applied advance for the next receipt" do
      advance = confirmed_advance(100)
      receipt = approved_receipt([ [ product_a, 1, 100 ] ])
      Inventory::GoodsReceiptVoider.new(goods_receipt_id: receipt.id, actor: approver, reason: "damaged").call

      expect(advance.reload.unapplied_amount).to eq(100)
      again = approved_receipt([ [ product_a, 1, 100 ] ])
      expect(applied_on(again)).to eq(100)
    end

    it "an advance application can't be reversed on its own" do
      confirmed_advance(100)
      receipt = approved_receipt([ [ product_a, 1, 100 ] ])
      row = receipt.financial_settlements.advance_applications.sole

      result = Inventory::GoodsReceiptSettlementReverser.new(goods_receipt_id: receipt.id, settlement_id: row.id,
                                                             actor: approver, reason: "x").call
      expect(result.error).to eq(I18n.t("inventory.goods_receipts.settlements.errors.advance_application_not_reversible"))
    end

    it "supplier payable reflects the advance (242 purchase, 100 advance → 142 outstanding)" do
      confirmed_advance(100)
      receipt = approved_receipt([ [ product_a, 2, 100 ], [ product_b, 1, 42 ] ])
      expect(Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: receipt.id, actor: approver).call).to be_ok

      report = Inventory::Reports::Purchases.new(business)
      row = report.rows.find { |r| r.receipt == receipt }
      expect(row).to have_attributes(total_value: 242, paid_amount: 100, outstanding_amount: 142)
      expect(report.total_outstanding).to eq(142)
    end

    describe "paying the remainder from employee custody (negative balance allowed)" do
      def set_balance(target)
        delta = target - custody.computed_balance
        custody.custody_transactions.create!(business: business, txn_type: "adjustment", amount: delta) unless delta.zero?
        custody.refresh_balance!
      end

      it "advance and remainder from the same custody: 242 − 100 advance → 142 due; 50 − 142 = −92" do
        set_balance(150)
        confirmed_advance(100, source_kind: "employee_custody", account: custody) # 150 → 50
        expect(custody.reload.computed_balance).to eq(50)

        receipt = approved_receipt([ [ product_a, 2, 100 ], [ product_b, 1, 42 ] ], kind: "employee_custody", account: custody)

        expect(applied_on(receipt)).to eq(100)
        expect(receipt.custody_transactions.sole.amount).to eq(-142)
        expect(custody.reload.computed_balance).to eq(-92)
        expect(custody.current_balance).to eq(-92)
        expect(receipt).to be_settled
        # One debit per real payment: the advance (−100) and the remainder (−142).
        expect(custody.custody_transactions.where(txn_type: "inventory_purchase").order(:id).pluck(:amount)).to eq([ -100, -142 ])
      end

      it "sufficient balance: remainder paid normally" do
        confirmed_advance(100)
        approved_receipt([ [ product_a, 2, 100 ], [ product_b, 1, 42 ] ], kind: "employee_custody", account: custody)
        expect(custody.reload.computed_balance).to eq(500 - 142)
      end

      it "zero balance: remainder still paid (0 − 142 = −142)" do
        set_balance(0)
        confirmed_advance(100)
        approved_receipt([ [ product_a, 2, 100 ], [ product_b, 1, 42 ] ], kind: "employee_custody", account: custody)
        expect(custody.reload.computed_balance).to eq(-142)
      end

      it "partial receipts paid from custody consume the advance once and pay only what's due" do
        request.items.find_by!(product: product_b).update_column(:quantity, 2) # two receipts take 1 each
        set_balance(50)
        confirmed_advance(150)

        first = approved_receipt([ [ product_a, 1, 100 ] ], kind: "employee_custody", account: custody)
        expect(applied_on(first)).to eq(100)
        expect(first.custody_transactions).to be_empty # fully covered by the advance
        expect(custody.reload.computed_balance).to eq(50)

        second = approved_receipt([ [ product_a, 1, 100 ], [ product_b, 1, 42 ] ], kind: "employee_custody", account: custody)
        expect(applied_on(second)).to eq(50)
        expect(second.custody_transactions.sole.amount).to eq(-92)
        expect(custody.reload.computed_balance).to eq(-42)

        third = approved_receipt([ [ product_b, 1, 42 ] ], kind: "employee_custody", account: custody)
        expect(applied_on(third)).to eq(0)
        expect(custody.reload.computed_balance).to eq(-84)
      end

      it "voiding the receipt restores the custody balance and releases the advance" do
        set_balance(50)
        advance = confirmed_advance(100)
        receipt = approved_receipt([ [ product_a, 2, 100 ], [ product_b, 1, 42 ] ], kind: "employee_custody", account: custody)
        expect(custody.reload.computed_balance).to eq(-92)

        expect(Inventory::GoodsReceiptVoider.new(goods_receipt_id: receipt.id, actor: approver, reason: "wrong").call).to be_ok
        expect(custody.reload.computed_balance).to eq(50)
        expect(advance.reload.unapplied_amount).to eq(100)
      end

      it "an inactive custody account is rejected at receiving" do
        confirmed_advance(100)
        receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, purchase_request: request,
                                                received_on: Date.current, created_by: requester,
                                                funding_source_kind: "employee_custody", funding_source: custody)
        receipt.items.build(product: product_a, quantity: 1, unit_cost: 100, purchase_request_item: request.items.first)
        receipt.save!
        receipt.update_column(:approval_status, "pending_approval")
        custody.update!(active: false)

        result = Inventory::GoodsReceiptApproval.new(goods_receipt_id: receipt.id, actor: approver).approve!
        expect(result.error).to eq(I18n.t("inventory.goods_receipts.errors.no_active_custody_account"))
        expect(receipt.reload.financial_settlements).to be_empty # advance not consumed either
      end
    end

    it "receiving a request without advances is unchanged" do
      receipt = approved_receipt([ [ product_a, 1, 100 ] ], kind: "company_cash")
      expect(receipt.financial_settlements.sole).to have_attributes(source_kind: "company_cash", amount: 100)
    end
  end

  describe "new funding beside legacy advances and receipt payments" do
    it "is not capped by what remains unpaid, and leaves the legacy supplier-payment figures untouched" do
      request.update!(responsible_employee: purchaser_with_custody(business, first_name: "Rami"))
      confirmed_advance(20)                                               # legacy supplier payment
      approved_receipt([ [ product_a, 1, 100 ] ], kind: "company_cash")    # 100 − 20 advance = 80 paid directly
      figures = -> { request.reload.then { |pr| [ pr.total_amount, pr.advances_total, pr.amount_remaining_after_advances, pr.unapplied_advances_total ] } }
      before = figures.()

      funded = Inventory::PurchaseRequestAdvanceRecorder.new(
        purchase_request_id: request.id, actor: recorder,
        params: { amount: 5000, source_kind: "company_cash", paid_on: Date.current }  # far above 242 − 20 − 80
      ).call
      expect(funded).to be_ok
      expect(funded.advance.reload).to be_confirmed # executed when recorded

      expect(figures.()).to eq(before) # 242, 20 legacy, 222 remaining, 0 unapplied
      expect(before).to eq([ 242, 20, 222, 0 ])
    end
  end
end
