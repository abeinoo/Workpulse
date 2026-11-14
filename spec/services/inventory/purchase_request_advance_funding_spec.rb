require "rails_helper"

# Purchase Request advances FUND the request's responsible employee's custody
# (PurchaseRequestAdvance#funding?) — never a supplier payment — and the funding
# is POSTED WHEN THE ADVANCE IS RECORDED, in one transaction (no second-person
# confirmation):
#   - employee custody transfer: source custody −, responsible custody + (one
#     linked "transfer" pair);
#   - company cash / bank: one "purchase_advance_funding" credit on the
#     responsible custody (no company cash/bank ledger exists — BUG-049).
# Reversal posts the opposite rows. Advances still pending from the old
# two-step workflow are only cancelled, never executed. Legacy supplier-payment
# advances: purchase_request_advances_spec.rb.
RSpec.describe "Purchase Request advance funding", type: :model do
  let(:business)  { create(:business) }
  let(:recorder)  { create(:user, :super_admin, business: business) }
  let(:reverser)  { create(:user, business: business) }
  let(:supplier)  { business.suppliers.create!(name: "Nile Beauty") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", average_cost_price: 1000) }

  # The requirement's example: Ahmed (source) 5,000; Mohamed (responsible) 2,000.
  let(:ahmed)   { purchaser_with_custody(business, first_name: "Ahmed", balance: 5000) }
  let(:mohamed) { purchaser_with_custody(business, first_name: "Mohamed", balance: 2000) }
  let(:ahmed_custody)   { custody_of(ahmed) }
  let(:mohamed_custody) { custody_of(mohamed) }

  # 3 × 1,000 = 3,000, Mohamed responsible.
  let(:request) do
    pr = business.purchase_requests.build(warehouse: warehouse, created_by: recorder, responsible_employee: mohamed)
    pr.items.build(product: product, quantity: 3, unit_price: 1000, supplier: supplier)
    pr.save!
    pr.update_column(:status, "approved")
    pr
  end

  def record(amount: 1000, source_kind: "employee_custody", source: ahmed_custody, actor: recorder, key: nil,
             reference: "TR-1", purchase_request: request)
    Inventory::PurchaseRequestAdvanceRecorder.new(
      purchase_request_id: purchase_request.id, actor: actor, idempotency_key: key,
      params: { amount: amount, source_kind: source_kind, custody_account_id: source&.id,
                paid_on: Date.current, reference: reference }
    ).call
  end

  def workflow(advance, actor: reverser) = Inventory::PurchaseRequestAdvanceWorkflow.new(advance_id: advance.id, actor: actor)

  def recorded(**)
    result = record(**)
    expect(result).to be_ok, result.error
    result.advance.reload
  end

  def message(key, **) = I18n.t("inventory.purchase_request_advances.errors.#{key}", **)

  def balances = [ ahmed_custody.reload.current_balance, mohamed_custody.reload.current_balance ]

  def ledger_snapshot
    { advances: PurchaseRequestAdvance.count, custody: CustodyTransaction.where.not(txn_type: "top_up").count,
      settlements: FinancialSettlement.count, balances: balances,
      audits: AuditLog.where(auditable_type: "PurchaseRequestAdvance").count }
  end

  describe "recording executes the funding immediately" do
    it "employee custody transfer: Ahmed 5,000 → 4,000, Mohamed 2,000 → 3,000, one linked pair, no supplier payment" do
      advance = recorded

      expect(advance).to have_attributes(status: "confirmed", created_by_id: recorder.id, confirmed_by_id: recorder.id,
                                         financial_settlement_id: nil, recipient_custody_account_id: mohamed_custody.id,
                                         custody_account_id: ahmed_custody.id, reference: "TR-1")
      expect(advance.confirmed_at).to be_present
      credit = advance.funding_transaction
      debit  = credit.transfer_counterparty
      expect(credit).to have_attributes(txn_type: "transfer", custody_account_id: mohamed_custody.id, amount: 1000,
                                        source: request, created_by_id: recorder.id)
      expect(debit).to have_attributes(txn_type: "transfer", custody_account_id: ahmed_custody.id, amount: -1000,
                                       transfer_counterparty_id: credit.id)
      expect(balances).to eq([ 4000, 3000 ])
      expect([ ahmed_custody.computed_balance, mohamed_custody.computed_balance ]).to eq([ 4000, 3000 ])
      expect(FinancialSettlement.count).to eq(0)
    end

    %w[company_cash bank_account].each do |kind|
      it "#{kind}: credits the responsible employee's custody once, distinguishable from a manual top-up" do
        advance = recorded(source_kind: kind, source: nil, reference: "BANK-77")

        expect(advance).to have_attributes(status: "confirmed", confirmed_by_id: recorder.id, custody_account_id: nil)
        credit = advance.funding_transaction
        expect(credit).to have_attributes(txn_type: "purchase_advance_funding", custody_account_id: mohamed_custody.id,
                                          amount: 1000, source: request, created_by_id: recorder.id)
        expect(credit).not_to be_top_up
        expect(credit.notes).to include("BANK-77")
        expect(advance.reference).to eq("BANK-77")
        expect(balances).to eq([ 5000, 3000 ])
        expect(CustodyTransaction.where.not(txn_type: "top_up").count).to eq(1)
        expect(FinancialSettlement.count).to eq(0)
      end
    end

    it "never creates a pending advance" do
      recorded
      recorded(source_kind: "company_cash", source: nil)
      recorded(source_kind: "bank_account", source: nil)
      expect(PurchaseRequestAdvance.pending).to be_empty
      expect(PurchaseRequestAdvance.where(funding_transaction_id: nil)).to be_empty
    end

    it "one audit entry per advance (create), naming the parties and the custody ledger rows" do
      advance = recorded
      credit  = advance.funding_transaction
      entry   = AuditLog.where(auditable: advance).sole

      expect(entry.action).to eq("create")
      expect(entry.actor_id).to eq(recorder.id)
      expect(entry.metadata).to include(
        "status" => "confirmed", "source_kind" => "employee_custody", "amount" => "1000.0",
        "custody_account_id" => ahmed_custody.id, "employee_id" => ahmed.id,
        "responsible_employee_id" => mohamed.id, "recipient_custody_account_id" => mohamed_custody.id,
        "funding_transaction_id" => credit.id, "funding_counterparty_id" => credit.transfer_counterparty_id
      )
      expect(entry.metadata["custody_entries"]).to contain_exactly(
        { "custody_transaction_id" => credit.id, "custody_account_id" => mohamed_custody.id, "amount" => "1000.0" },
        { "custody_transaction_id" => credit.transfer_counterparty_id, "custody_account_id" => ahmed_custody.id,
          "amount" => "-1000.0" }
      )

      company = recorded(source_kind: "company_cash", source: nil)
      expect(AuditLog.where(auditable: company).sole.metadata).to include(
        "funding_counterparty_id" => nil,
        "custody_entries" => [ { "custody_transaction_id" => company.funding_transaction_id,
                                 "custody_account_id" => mohamed_custody.id, "amount" => "1000.0" } ]
      )
    end

    it "is never a supplier payment, an expense or a receipt deduction" do
      expect {
        recorded
        recorded(source_kind: "company_cash", source: nil)
      }.not_to change(Expense, :count)

      expect(FinancialSettlement.count).to eq(0)
      expect(request.reload.advances_total).to eq(0)
      expect(request.amount_remaining_after_advances).to eq(3000)
      expect(request.unapplied_advances_total).to eq(0)
      expect(request.confirmed_funding_total).to eq(2000)
      expect(request.advances.map(&:unapplied_amount)).to all(eq(0))
    end

    it "an insufficient source balance follows the custody rule: no limit (500 − 1,000 = −500)" do
      small = purchaser_with_custody(business, first_name: "Rana", balance: 500)
      recorded(source: custody_of(small))
      expect(custody_of(small).reload.current_balance).to eq(-500)
    end
  end

  describe "refusals (nothing written)" do
    it "requires the request to have a responsible employee who is still eligible" do
      request.update_column(:responsible_employee_id, nil)
      expect(record.error).to eq(message(:responsible_employee_required))

      request.update_column(:responsible_employee_id, mohamed.id)
      mohamed.update_column(:permission_role_id, nil)
      expect(record.error).to eq(message(:responsible_employee_ineligible))

      mohamed.update_column(:permission_role_id, purchaser_role_for(business).id)
      mohamed_custody.update_column(:active, false)
      expect(record(source_kind: "company_cash", source: nil).error).to eq(message(:responsible_employee_ineligible))
      expect(ledger_snapshot).to include(advances: 0, custody: 0, audits: 0)
    end

    it "refuses the responsible employee as the source of a transfer" do
      expect(record(source: mohamed_custody, actor: mohamed).error).to eq(message(:recorded_by_responsible_employee))
      expect(record(source: mohamed_custody).error).to eq(message(:source_is_responsible_employee))
    end

    it "requires a source with an active custody account and the purchasing permission (existing payer rule)" do
      mohamed_custody
      no_permission = create(:custody_account, business: business, user: create(:user, business: business))
      inactive      = custody_of(purchaser_with_custody(business)).tap { |a| a.update_column(:active, false) }
      [ nil, no_permission, inactive ].each { |source| expect(record(source: source).error).to eq(message(:custody_account_required)) }

      # Without manage_employee_balances only one's own account.
      other = purchaser_with_custody(business, first_name: "Sami")
      expect(record(actor: other).error).to eq(message(:custody_account_required))
      expect(ledger_snapshot).to include(advances: 0, custody: 0)
    end

    it "zero, negative and non-numeric amounts" do
      [ 0, "0.00", -1, "-250", "0.004", "abc", "" ].each do |amount|
        expect(record(amount: amount).error).to eq(message(:amount_must_be_positive)), "amount #{amount.inspect}"
      end
      expect(ledger_snapshot).to include(advances: 0, custody: 0, audits: 0)
    end

    it "Finance & Sales refusing under the account locks rolls the advance back" do
      snapshot = ledger_snapshot
      %i[custody_account_inactive employee_ineligible].each do |status|
        allow(Inventory::PurchaseRequestAdvanceEffects).to receive(:advance_funded)
          .and_return(Inventory::PurchaseRequestAdvanceEffects::Funding.new(status: status))
        expect(record(key: SecureRandom.uuid).error).to eq(message(status))
        expect(ledger_snapshot).to eq(snapshot)
      end
    end
  end

  describe "who may record — no second person" do
    it "the source employee records a transfer from their own custody; it is executed at once" do
      advance = recorded(actor: ahmed)
      expect(advance).to have_attributes(status: "confirmed", created_by_id: ahmed.id, confirmed_by_id: ahmed.id)
      expect(balances).to eq([ 4000, 3000 ])
    end

    it "never the responsible employee, for any method — even with manage_employee_balances" do
      mohamed.permission_role.update!(permissions: mohamed.permission_role.permissions + %w[view_employee_balances manage_employee_balances])
      [ [ "employee_custody", ahmed_custody ], [ "company_cash", nil ], [ "bank_account", nil ] ].each do |kind, source|
        expect(record(actor: mohamed, source_kind: kind, source: source).error)
          .to eq(message(:recorded_by_responsible_employee))
      end
      expect(ledger_snapshot).to include(advances: 0, custody: 0, balances: [ 5000, 2000 ])
    end
  end

  describe "duplicates" do
    it "a repeated submission (same idempotency key) returns the first advance: one advance, one posting" do
      key = SecureRandom.uuid
      first = record(key: key)
      again = record(key: key)

      expect([ first, again ]).to all(be_ok)
      expect(again.advance.id).to eq(first.advance.id)
      expect(ledger_snapshot).to include(advances: 1, custody: 2, balances: [ 4000, 3000 ], audits: 1)
    end
  end

  describe "atomic: any step failing leaves no trace" do
    it "the responsible credit fails after the source debit: no advance, no rows, balances unchanged, no audit" do
      snapshot = ledger_snapshot
      allow_any_instance_of(CustodyTransaction).to receive(:save!).and_wrap_original do |original, *args, **kwargs|
        txn = original.receiver
        if txn.amount.positive?
          txn.errors.add(:base, "credit refused")
          raise ActiveRecord::RecordInvalid, txn
        end
        original.call(*args, **kwargs)
      end

      expect(record.error).to eq("credit refused")
      expect(ledger_snapshot).to eq(snapshot)
    end

    it "linking the funding row to the advance fails after posting: everything rolls back" do
      snapshot = ledger_snapshot
      allow_any_instance_of(PurchaseRequestAdvance).to receive(:update!).and_wrap_original do |original, *args, **kwargs|
        row = original.receiver
        if kwargs.key?(:funding_transaction_id)
          row.errors.add(:base, "advance refused")
          raise ActiveRecord::RecordInvalid, row
        end
        original.call(*args, **kwargs)
      end

      expect(record(source_kind: "bank_account", source: nil).error).to eq("advance refused")
      expect(ledger_snapshot).to eq(snapshot)
    end
  end

  # The amount is any positive figure: funding is custody money for the
  # purchase, not a supplier payment, so an excess over the request total stays
  # in the responsible employee's custody and nothing on the request moves.
  describe "amounts below, equal to and above the request total (3,000)" do
    sources = { "employee_custody" => true, "company_cash" => false, "bank_account" => false }

    def request_figures(pr = request.reload)
      { total: pr.total_amount, items: pr.items.map { |i| [ i.product_id, i.quantity, i.unit_price ] },
        advances_total: pr.advances_total, remaining: pr.amount_remaining_after_advances,
        unapplied: pr.unapplied_advances_total, settlements: FinancialSettlement.count }
    end

    sources.each do |kind, transfer|
      { "below" => 1000, "equal to" => 3000, "above" => 4500, "far above (100×)" => 300_000 }.each do |label, amount|
        it "#{kind}, #{label} the total: the full amount funds the responsible custody at once; the request is untouched" do
          before  = request_figures
          advance = recorded(amount: amount, source_kind: kind, source: (ahmed_custody if transfer), key: SecureRandom.uuid)

          expect(advance).to have_attributes(amount: amount, status: "confirmed")
          credit = advance.funding_transaction
          expect(credit).to have_attributes(custody_account_id: mohamed_custody.id, amount: amount,
                                            txn_type: transfer ? "transfer" : "purchase_advance_funding")
          if transfer
            expect(credit.transfer_counterparty).to have_attributes(custody_account_id: ahmed_custody.id, amount: -amount)
            expect(balances).to eq([ 5000 - amount, 2000 + amount ]) # the source may go negative (custody rule)
          else
            expect(balances).to eq([ 5000, 2000 + amount ])
          end
          expect([ ahmed_custody.computed_balance, mohamed_custody.computed_balance ]).to eq(balances)

          # Not a supplier payment: total, items, supplier balance and deduction unchanged.
          expect(request_figures).to eq(before)
          expect(request.confirmed_funding_total).to eq(amount)
          expect(advance.unapplied_amount).to eq(0)
          expect(AuditLog.where(auditable: advance, action: "create").sole.metadata).to include("amount" => amount.to_d.to_s)
        end
      end

      it "#{kind}: an excess advance reverses with its original amount; the originals stay untouched" do
        advance  = recorded(amount: 12_000, source_kind: kind, source: (ahmed_custody if transfer))
        original = advance.funding_transaction
        expect(workflow(advance).reverse!(reason: "over-funded")).to be_ok

        back = advance.reload.funding_reversal_transaction
        expect(advance).to have_attributes(status: "reversed", reversed_by_id: reverser.id, reversal_reason: "over-funded")
        expect(back).to have_attributes(custody_account_id: mohamed_custody.id, amount: -12_000)
        expect(back.transfer_counterparty).to have_attributes(custody_account_id: ahmed_custody.id, amount: 12_000) if transfer
        expect(original.reload).to have_attributes(amount: 12_000, voided_at: nil)
        expect(balances).to eq([ 5000, 2000 ])
        expect(request.reload.confirmed_funding_total).to eq(0)
        expect(AuditLog.where(auditable: advance).pluck(:action)).to contain_exactly("create", "reverse")
      end
    end

    it "several advances beyond the total all record" do
      recorded(amount: 2500)
      recorded(amount: 1500, source_kind: "company_cash", source: nil)
      recorded(amount: 4000, source_kind: "bank_account", source: nil)
      expect(request.reload.confirmed_funding_total).to eq(8000) # on a 3,000 request
      expect(balances).to eq([ 2500, 10_000 ])
    end

    describe "the Goods Receipt after excess funding (Mohamed funded 10,000 by transfer + 5,000 company cash)" do
      before do
        recorded(amount: 10_000)
        recorded(amount: 5000, source_kind: "company_cash", source: nil)
      end

      def approve_receipt(quantity:, kind:, account: nil)
        receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, purchase_request: request,
                                                received_on: Date.current, created_by: recorder,
                                                funding_source_kind: kind, funding_source: account)
        receipt.items.build(product: product, quantity: quantity, unit_cost: 1000, purchase_request_item: request.items.sole)
        receipt.save!
        receipt.update_column(:approval_status, "pending_approval")
        result = Inventory::GoodsReceiptApproval.new(goods_receipt_id: receipt.id, actor: reverser).approve!
        expect(result).to be_ok, result.error
        receipt.reload
      end

      it "nothing is deducted as a supplier payment: the full value is due and paid once, the excess stays in custody" do
        expect(balances).to eq([ -5000, 17_000 ])

        receipt = approve_receipt(quantity: 3, kind: "employee_custody", account: mohamed_custody)

        allocator = Inventory::PurchaseRequestAdvanceAllocator.new(receipt)
        expect(receipt.financial_settlements.advance_applications).to be_empty
        expect(allocator.receipt_amount_due).to eq(3000)
        expect(receipt.financial_settlements.sum(:amount)).to eq(3000) # paid once, from the custody
        expect(balances).to eq([ -5000, 14_000 ])                      # 17,000 − 3,000; 12,000 excess remains
        expect(request.reload).to have_attributes(total_amount: 3000, advances_total: 0, unapplied_advances_total: 0)
        expect(request.confirmed_funding_total).to eq(15_000)
      end

      it "a receipt on supplier credit owes the full value: funding is never a supplier payment" do
        receipt = approve_receipt(quantity: 2, kind: "supplier_credit")
        expect(Inventory::PurchaseRequestAdvanceAllocator.new(receipt).receipt_amount_due).to eq(2000)
        expect(receipt.financial_settlements.advance_applications).to be_empty
        expect(balances).to eq([ -5000, 17_000 ])
      end
    end
  end

  describe "reversal" do
    it "employee transfer: the opposite pair restores both balances; originals untouched; audited" do
      advance  = recorded
      original = advance.funding_transaction
      expect(workflow(advance).reverse!(reason: "  not needed  ")).to be_ok

      advance.reload
      expect(advance).to have_attributes(status: "reversed", reversed_by_id: reverser.id, reversal_reason: "not needed")
      back = advance.funding_reversal_transaction
      expect(back).to have_attributes(txn_type: "transfer", custody_account_id: mohamed_custody.id, amount: -1000)
      expect(back.transfer_counterparty).to have_attributes(custody_account_id: ahmed_custody.id, amount: 1000)
      expect(original.reload).to have_attributes(amount: 1000, voided_at: nil)
      expect(balances).to eq([ 5000, 2000 ])
      expect(AuditLog.where(auditable: advance, action: "reverse").sole.metadata).to include(
        "funding_transaction_id" => original.id, "funding_reversal_transaction_id" => back.id,
        "funding_reversal_counterparty_id" => back.transfer_counterparty_id, "reason" => "not needed"
      )
    end

    it "company funding: one purchase_advance_funding_reversal debit on the responsible custody" do
      advance = recorded(source_kind: "company_cash", source: nil)
      expect(workflow(advance).reverse!(reason: "returned to the safe")).to be_ok

      expect(advance.reload.funding_reversal_transaction)
        .to have_attributes(txn_type: "purchase_advance_funding_reversal", custody_account_id: mohamed_custody.id, amount: -1000)
      expect(balances).to eq([ 5000, 2000 ])
      expect(request.reload.confirmed_funding_total).to eq(0)
    end

    it "is never repeated, and a reason is required" do
      advance = recorded
      expect(workflow(advance).reverse!(reason: " ").error).to eq(message(:reason_required))
      workflow(advance).reverse!(reason: "once")
      snapshot = ledger_snapshot
      expect(workflow(advance).reverse!(reason: "twice").error).to eq(message(:invalid_transition))
      expect(ledger_snapshot).to eq(snapshot)
    end

    it "is refused (nothing written) if any part fails" do
      advance  = recorded
      snapshot = ledger_snapshot
      allow_any_instance_of(CustodyTransaction).to receive(:save!).and_wrap_original do |original, *args, **kwargs|
        txn = original.receiver
        if txn.amount.positive?
          txn.errors.add(:base, "credit refused")
          raise ActiveRecord::RecordInvalid, txn
        end
        original.call(*args, **kwargs)
      end

      expect(workflow(advance).reverse!(reason: "oops").error).to eq("credit refused")
      expect(ledger_snapshot).to eq(snapshot)
      expect(advance.reload).to be_confirmed
    end
  end

  describe "the funding rows cannot be changed outside the advance" do
    it "refuses voiding any of them directly (service and model) — reverse the advance instead" do
      transfer = recorded.funding_transaction
      company  = recorded(amount: 500, source_kind: "company_cash", source: nil).funding_transaction
      [ transfer, transfer.transfer_counterparty, company ].each do |row|
        expect(Finance::TransactionVoider.new(row, user: recorder, reason: "oops").call.error)
          .to eq(I18n.t("finance.custody.errors.advance_funding_linked"))
        expect(row.update(voided_at: Time.current, void_reason: "oops")).to be(false)
      end
      expect(balances).to eq([ 4000, 3500 ]) # 2,000 + 1,000 transfer + 500 company
    end

    it "still voids a manual custody transfer pair as before" do
      Finance::CustodyTransactionCreator.new(ahmed_custody, actor: recorder,
                                             params: { txn_type: "transfer", magnitude: "50",
                                                       target_account_id: mohamed_custody.id }).call
      manual = CustodyTransaction.find_by!(txn_type: "transfer", custody_account: ahmed_custody)
      expect(Finance::TransactionVoider.new(manual, user: recorder, reason: "typo").call).to be_ok
    end
  end

  describe "historical advances (backward compatibility)" do
    it "the confirmation step no longer exists anywhere" do
      expect(Inventory::PurchaseRequestAdvanceWorkflow.method_defined?(:confirm!)).to be(false)
      expect(PurchaseRequestAdvancePolicy.method_defined?(:confirm?)).to be(false)
      expect(Rails.application.routes.named_routes.key?(:confirm_inventory_purchase_request_advance)).to be(false)
    end

    it "a funding advance still pending from the old workflow is never executed — only cancelled, with a reason" do
      old = old_pending_funding_advance(request: request, amount: 700, actor: recorder)
      snapshot = ledger_snapshot

      expect(old).to be_pending
      expect(request.reload.confirmed_funding_total).to eq(0)          # it never counts as funded
      expect(workflow(old).cancel!(reason: " ").error).to eq(message(:reason_required))
      expect(workflow(old).reverse!(reason: "x").error).to eq(message(:invalid_transition))
      expect(ledger_snapshot).to eq(snapshot)

      expect(workflow(old).cancel!(reason: "re-recorded")).to be_ok
      expect(old.reload).to have_attributes(status: "cancelled", cancelled_by_id: reverser.id,
                                            cancellation_reason: "re-recorded", funding_transaction_id: nil)
      expect(ledger_snapshot).to include(custody: snapshot[:custody], balances: [ 5000, 2000 ])
      expect(AuditLog.where(auditable: old, action: "cancel")).to exist

      # …and a new advance is recorded (and executed) in its place.
      expect(recorded(amount: 700, source_kind: "company_cash", source: nil)).to be_confirmed
      expect(balances).to eq([ 5000, 2700 ])
    end

    it "an old pending advance still blocks changing the responsible employee until it is cancelled" do
      old = old_pending_funding_advance(request: request, amount: 100, actor: recorder)
      expect(request.reload.responsible_employee_locked?).to be(true)
      workflow(old).cancel!(reason: "obsolete")
      expect(request.reload.responsible_employee_locked?).to be(false)
    end

    describe "legacy supplier-payment advances" do
      let(:legacy_request) do
        pr = business.purchase_requests.build(supplier: supplier, created_by: recorder)
        pr.items.build(product: product, quantity: 1, unit_price: 1000, source_warehouse: warehouse)
        pr.save!
        pr.update_column(:status, "approved")
        pr
      end

      it "a pending legacy advance is only cancelled, with its audit trail" do
        pending_legacy = legacy_request.advances.create!(business: business, amount: 100, source_kind: "company_cash",
                                                         paid_on: Date.current, created_by: recorder)
        policy = PurchaseRequestAdvancePolicy.new(create(:user, :super_admin, business: business), pending_legacy)

        expect(policy.cancel?).to be(true)
        expect(policy.reverse?).to be(false)
        expect(workflow(pending_legacy).cancel!(reason: "re-recorded as funding")).to be_ok
        expect(AuditLog.where(auditable: pending_legacy, action: "cancel")).to exist
        expect(FinancialSettlement.count).to eq(0)
      end

      it "a confirmed legacy advance keeps its supplier payment and reverses as before" do
        legacy = legacy_confirmed_advance(request: legacy_request, amount: 100, actor: recorder)
        expect(legacy).to be_legacy
        expect(legacy_request.reload.advances_total).to eq(100)

        expect(workflow(legacy).reverse!(reason: "refund")).to be_ok
        expect(legacy_request.reload.advances_total).to eq(0)
      end

      it "a request without a responsible employee takes no new advance" do
        expect(record(purchase_request: legacy_request, source_kind: "company_cash", source: nil).error)
          .to eq(message(:responsible_employee_required))
      end
    end
  end
end
