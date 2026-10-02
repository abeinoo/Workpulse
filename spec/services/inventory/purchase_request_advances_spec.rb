require "rails_helper"

# Advance payments on a Purchase Request, end to end through the services:
# recording, confirmation (custody / company), totals, cancellation, reversal,
# and how receipt approval consumes advances (full, partial, multiple).
RSpec.describe "Purchase Request advance payments", type: :model do
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
    pr = PurchaseRequest.new(business: business, supplier: supplier, created_by: requester)
    pr.items.build(product: product_a, quantity: 2, unit_price: 100, source_warehouse: warehouse)
    pr.items.build(product: product_b, quantity: 1, unit_price: 42, source_warehouse: warehouse)
    pr.save!
    pr.update_column(:status, "approved")
    pr
  end

  def record(amount, source_kind: "company_cash", account: nil, actor: recorder, key: nil, **extra)
    Inventory::PurchaseRequestAdvanceRecorder.new(
      purchase_request_id: request.id, actor: actor, idempotency_key: key,
      params: { amount: amount, source_kind: source_kind, custody_account_id: account&.id,
                paid_on: Date.current, reference: "DEP-1", notes: "deposit" }.merge(extra)
    ).call
  end

  def workflow(advance, actor: confirmer)
    Inventory::PurchaseRequestAdvanceWorkflow.new(advance_id: advance.id, actor: actor)
  end

  def confirmed_advance(amount, **opts)
    advance = record(amount, **opts).advance
    expect(workflow(advance).confirm!).to be_ok
    advance.reload
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

  describe "recording (pending)" do
    it "creates a pending advance and moves no money" do
      custody
      result = record(100, source_kind: "employee_custody", account: custody)

      expect(result).to be_ok
      expect(result.advance).to have_attributes(status: "pending", amount: 100, custody_account_id: custody.id,
                                                created_by_id: recorder.id, reference: "DEP-1", notes: "deposit")
      expect(request.reload.financial_settlements).to be_empty
      expect(custody.reload.computed_balance).to eq(500)
      expect(request.advances_total).to eq(0)
    end

    it "rejects amount <= 0, an invalid source, and a future date" do
      expect(record(0).error).to eq(I18n.t("inventory.purchase_request_advances.errors.amount_must_be_positive"))
      expect(record(10, source_kind: "supplier_credit").error)
        .to eq(I18n.t("inventory.purchase_request_advances.errors.invalid_source_kind"))
      expect(record(10, source_kind: "purchase_request_advance").error)
        .to eq(I18n.t("inventory.purchase_request_advances.errors.invalid_source_kind"))
      expect(record(10, paid_on: Date.current + 3).error)
        .to eq(I18n.t("inventory.purchase_request_advances.errors.future_payment_date"))
      expect(PurchaseRequestAdvance.count).to eq(0)
    end

    it "rejects more than the request's remaining unpaid amount, counting pending advances" do
      expect(record(243)).not_to be_ok
      expect(record(200)).to be_ok
      expect(record(50).error).to include("42.00")
      expect(record(42)).to be_ok
    end

    it "is only allowed while the request is approved / partially received" do
      request.update_column(:status, "pending_approval")
      expect(record(10).error).to eq(I18n.t("inventory.purchase_request_advances.errors.not_allowed_for_status"))
    end

    it "requires a custody account the actor may use" do
      custody
      plain_user = create(:user, business: business)
      other_account = create(:custody_account, business: business, user: create(:user, business: business))

      expect(record(10, source_kind: "employee_custody", account: nil).error)
        .to eq(I18n.t("inventory.purchase_request_advances.errors.custody_account_required"))
      # Not their own and no manage_employee_balances → not selectable.
      expect(record(10, source_kind: "employee_custody", account: other_account, actor: plain_user).error)
        .to eq(I18n.t("inventory.purchase_request_advances.errors.custody_account_required"))
      # Their own account is always selectable.
      own = create(:custody_account, business: business, user: plain_user)
      own.custody_transactions.create!(business: business, txn_type: "top_up", amount: 20)
      expect(record(10, source_kind: "employee_custody", account: own, actor: plain_user)).to be_ok
    end

    it "rejects an employee with no custody account, or an inactive one — never creates one" do
      no_account_actor = create(:user, :super_admin, business: business)
      expect(record(10, source_kind: "employee_custody", account: nil, actor: no_account_actor).error)
        .to eq(I18n.t("inventory.purchase_request_advances.errors.custody_account_required"))
      expect(record(10, source_kind: "employee_custody", account: nil, custody_account_id: 999_999).error)
        .to eq(I18n.t("inventory.purchase_request_advances.errors.custody_account_required"))

      custody.update!(active: false)
      expect(record(10, source_kind: "employee_custody", account: custody).error)
        .to eq(I18n.t("inventory.purchase_request_advances.errors.custody_account_required"))
      expect(CustodyAccount.count).to eq(1)
      expect(PurchaseRequestAdvance.count).to eq(0)
    end

    it "returns the same advance for a repeated idempotency key (double submit / retry)" do
      key = SecureRandom.uuid
      first  = record(100, key: key)
      second = record(100, key: key)

      expect(second.advance).to eq(first.advance)
      expect(PurchaseRequestAdvance.count).to eq(1)
    end
  end

  describe "confirmation" do
    it "custody: posts a PR settlement and the linked custody debit, traceable from both sides" do
      advance = confirmed_advance(100, source_kind: "employee_custody", account: custody)

      expect(advance).to have_attributes(status: "confirmed", confirmed_by_id: confirmer.id)
      expect(advance.confirmed_at).to be_present
      settlement = advance.financial_settlement
      expect(settlement).to have_attributes(settleable: request, funding_source: custody, amount: 100,
                                            source_kind: "employee_custody", created_by_id: confirmer.id)

      txn = settlement.custody_transaction
      expect(txn).to have_attributes(txn_type: "inventory_purchase", amount: -100, source: request,
                                     custody_account_id: custody.id)
      expect(custody.reload.computed_balance).to eq(400)
      expect(custody.current_balance).to eq(400)
      # The custody row can't be voided directly — only through the advance reversal.
      expect(Finance::TransactionVoider.new(txn, user: recorder, reason: "x").call).not_to be_ok
    end

    it "company payment: records the settlement without touching any custody" do
      custody
      advance = confirmed_advance(50, source_kind: "company_cash")

      expect(advance.financial_settlement).to have_attributes(source_kind: "company_cash", funding_source_id: nil, amount: 50)
      expect(CustodyTransaction.where.not(txn_type: "top_up")).to be_empty
      expect(custody.reload.computed_balance).to eq(500)
    end

    it "updates totals: total, advances, remaining, count" do
      confirmed_advance(100, source_kind: "employee_custody", account: custody)
      confirmed_advance(50, source_kind: "company_cash")

      request.reload
      expect(request.total_amount).to eq(242)
      expect(request.advances_total).to eq(150)
      expect(request.amount_remaining_after_advances).to eq(92)
      expect(request.advances.confirmed.count).to eq(2)
      expect(request.unapplied_advances_total).to eq(150)
    end

    describe "negative custody balances are valid" do
      def drain_to(balance)
        custody.custody_transactions.create!(business: business, txn_type: "adjustment", amount: balance - 500)
        custody.refresh_balance!
      end

      it "sufficient balance: 500 − 100 → 400" do
        confirmed_advance(100, source_kind: "employee_custody", account: custody)
        expect(custody.reload.computed_balance).to eq(400)
      end

      it "insufficient balance: 50 − 100 → −50, recorded in the ledger and the cached balance" do
        drain_to(50)
        advance = confirmed_advance(100, source_kind: "employee_custody", account: custody)

        expect(advance).to be_confirmed
        expect(advance.financial_settlement.custody_transaction).to have_attributes(amount: -100, txn_type: "inventory_purchase")
        expect(custody.reload.computed_balance).to eq(-50)
        expect(custody.current_balance).to eq(-50)
        expect(request.reload.advances_total).to eq(100)
      end

      it "zero balance: 0 − 100 → −100" do
        drain_to(0)
        confirmed_advance(100, source_kind: "employee_custody", account: custody)
        expect(custody.reload.computed_balance).to eq(-100)
      end

      it "the balance dropping after recording does not block confirmation" do
        advance = record(100, source_kind: "employee_custody", account: custody).advance
        drain_to(20)

        expect(workflow(advance).confirm!).to be_ok
        expect(custody.reload.computed_balance).to eq(-80)
      end

      it "reversal from a negative balance restores it exactly (−50 → 50)" do
        drain_to(50)
        advance = confirmed_advance(100, source_kind: "employee_custody", account: custody)
        expect(workflow(advance).reverse!(reason: "deposit refunded")).to be_ok

        expect(custody.reload.computed_balance).to eq(50)
        expect(custody.current_balance).to eq(50)
      end

      it "a double confirm still deducts only once when going negative" do
        drain_to(10)
        advance = record(100, source_kind: "employee_custody", account: custody).advance
        expect(workflow(advance).confirm!).to be_ok
        expect(workflow(advance).confirm!).not_to be_ok

        expect(custody.reload.computed_balance).to eq(-90)
        expect(custody.custody_transactions.where(txn_type: "inventory_purchase").count).to eq(1)
      end
    end

    it "a second confirm (double click / retry) is refused — custody is debited once" do
      advance = record(100, source_kind: "employee_custody", account: custody).advance
      expect(workflow(advance).confirm!).to be_ok
      second = workflow(advance).confirm!

      expect(second).not_to be_ok
      expect(custody.reload.computed_balance).to eq(400)
      expect(request.reload.financial_settlements.count).to eq(1)
    end

    it "blocks the recorder from confirming their own advance (owner exempt)" do
      maker = create(:user, business: business)
      advance = record(10, actor: maker).advance
      expect(workflow(advance, actor: maker).confirm!.error).to eq(Approvals::SelfApproval.error_message)
      expect(workflow(advance, actor: recorder).confirm!).to be_ok # super admin owner
    end

    it "writes audit entries with actor, amount, source, custody, request and supplier" do
      advance = confirmed_advance(100, source_kind: "employee_custody", account: custody)

      logs = AuditLog.where(auditable: advance).order(:id)
      expect(logs.map(&:action)).to eq(%w[create confirm])
      expect(logs.first.actor).to eq(recorder)
      expect(logs.last.actor).to eq(confirmer)
      expect(logs.last.metadata).to include("purchase_request_id" => request.id, "supplier_id" => supplier.id,
                                            "amount" => "100.0", "source_kind" => "employee_custody",
                                            "custody_account_id" => custody.id, "employee_id" => requester.id)
    end
  end

  describe "cancellation and reversal" do
    it "a cancelled pending advance never counts" do
      advance = record(100).advance
      expect(workflow(advance).cancel!(reason: "")).not_to be_ok
      expect(workflow(advance).cancel!(reason: "supplier waived deposit")).to be_ok

      expect(advance.reload).to have_attributes(status: "cancelled", cancelled_by_id: confirmer.id,
                                                cancellation_reason: "supplier waived deposit")
      expect(request.reload.amount_remaining_after_advances).to eq(242)
      expect(workflow(advance).confirm!).not_to be_ok
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
      cancelled = record(60).advance
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

  describe "capacity after receipt payments" do
    it "counts direct receipt payments so an advance can't overpay the request" do
      approved_receipt([ [ product_a, 2, 100 ] ], kind: "company_cash") # 200 paid directly
      expect(record(43).error).to include("42.00")
      expect(record(42)).to be_ok
    end
  end
end
