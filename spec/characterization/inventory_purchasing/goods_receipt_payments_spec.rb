require "rails_helper"

# Characterization (Batch S — Inventory & Purchasing → Finance & Sales goods-receipt
# payment writes, module-boundaries.md §14.2 #6 write half; M1) — the CURRENT
# financial effects of the four goods-receipt services, pinned against unchanged
# code before they move behind an Inventory-defined contract
# (docs/architecture/inventory-finance-goods-receipt-payments-baseline-failures.txt):
#
#   Inventory::GoodsReceiptApproval#approve!  (incl. PurchaseRequestAdvanceAllocator#apply!)
#   Inventory::GoodsReceiptSettlementRecorder
#   Inventory::GoodsReceiptSettlementReverser
#   Inventory::GoodsReceiptVoider
#
# Every FinancialSettlement and CustodyTransaction they write is compared field by
# field, with the custody account's current_balance, the receipt's state and the
# audit rows. Failure paths inject a failure at each later write and prove nothing
# financial is left behind. Concurrency lives in goods_receipt_payments_concurrency_spec.rb.
RSpec.describe "Characterization: goods-receipt payment writes (Batch S M1)", type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:now)       { Time.zone.local(2026, 10, 21, 10, 0, 0) }
  let(:business)  { create(:business) }
  let(:requester) { create(:user, business: business, first_name: "Req") }
  let(:approver)  { create(:user, business: business, first_name: "App") }
  let(:payer)     { create(:user, business: business, first_name: "Pay") }
  let(:supplier)  { business.suppliers.create!(name: "Nile Beauty") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product_a) { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 0, average_cost_price: 0) }
  let(:product_b) { business.products.create!(name: "Conditioner", sku: "CO-1", initial_cost_price: 0, average_cost_price: 0) }

  # The requester's custody, funded with 1,000.
  let(:custody) { funded_custody(requester, 1000) }

  around { |example| travel_to(now) { example.run } }

  def funded_custody(user, amount, active: true)
    create(:custody_account, business: business, user: user).tap do |account|
      account.custody_transactions.create!(business: business, txn_type: "top_up", amount: amount)
      account.refresh_balance!
      account.update!(active: false) unless active
    end
  end

  # 2 × 100 + 1 × 50 = 250, pending approval.
  def pending_receipt(kind: "employee_custody", account: custody, request: nil, lines: [ [ product_a, 2, 100 ], [ product_b, 1, 50 ] ])
    receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, purchase_request: request,
                                            received_on: Date.current, created_by: requester,
                                            funding_source_kind: kind, funding_source: (account if kind == "employee_custody"))
    lines.each do |product, qty, cost|
      receipt.items.build(product: product, quantity: qty, unit_cost: cost,
                          purchase_request_item: request&.items&.find_by!(product: product))
    end
    receipt.save!
    receipt.update_column(:approval_status, "pending_approval")
    receipt
  end

  def approve(receipt, actor: approver) = Inventory::GoodsReceiptApproval.new(goods_receipt_id: receipt.id, actor: actor).approve!

  def approved_receipt(**)
    receipt = pending_receipt(**)
    result = approve(receipt)
    raise "approval failed: #{result.error}" unless result.ok?

    receipt.reload
  end

  def record_settlement(receipt, actor: payer, **params)
    Inventory::GoodsReceiptSettlementRecorder.new(receipt.id, actor: actor, params: params).call
  end

  def reverse(receipt, settlement, actor: payer, reason: "wrong custody")
    Inventory::GoodsReceiptSettlementReverser.new(goods_receipt_id: receipt.id, settlement_id: settlement.id,
                                                  actor: actor, reason: reason).call
  end

  def void(receipt, actor: approver, reason: "wrong supplier")
    Inventory::GoodsReceiptVoider.new(goods_receipt_id: receipt.id, actor: actor, reason: reason).call
  end

  def fields_of(settlement)
    { settleable: [ settlement.settleable_type, settlement.settleable_id ],
      funding_source: [ settlement.funding_source_type, settlement.funding_source_id ],
      source_kind: settlement.source_kind, reference: settlement.reference, amount: settlement.amount.to_s,
      settled_at: settlement.settled_at, created_by_id: settlement.created_by_id, notes: settlement.notes,
      reverses_settlement_id: settlement.reverses_settlement_id }
  end

  def fields_of_txn(txn)
    { custody_account_id: txn.custody_account_id, business_id: txn.business_id, txn_type: txn.txn_type,
      amount: txn.amount.to_s, source: [ txn.source_type, txn.source_id ],
      financial_settlement_id: txn.financial_settlement_id, created_by_id: txn.created_by_id, notes: txn.notes }
  end

  def settlements_of(receipt) = FinancialSettlement.where(settleable: receipt).order(:id).to_a
  def custody_txns_of(account) = CustodyTransaction.where(custody_account: account).where.not(txn_type: "top_up").order(:id).to_a
  def balance_of(account) = account.reload.current_balance.to_s
  def audits_of(receipt, action) = AuditLog.where(auditable: receipt, action: action).order(:id).to_a
  def gr(receipt) = [ "GoodsReceipt", receipt.id ]

  # ── Approval ───────────────────────────────────────────────────────────────
  describe "GoodsReceiptApproval#approve!" do
    it "employee custody: one settlement for the amount due, a linked custody debit and the balance, in the approval" do
      receipt = pending_receipt
      expect(approve(receipt)).to be_ok

      settlement = settlements_of(receipt).sole
      expect(fields_of(settlement)).to eq(
        settleable: gr(receipt), funding_source: [ "CustodyAccount", custody.id ], source_kind: "employee_custody",
        reference: nil, amount: "250.0", settled_at: now, created_by_id: approver.id,
        notes: "Inventory Purchase - Goods Receipt #{receipt.receipt_number}", reverses_settlement_id: nil
      )
      expect(custody_txns_of(custody).map { fields_of_txn(_1) }).to eq([ {
        custody_account_id: custody.id, business_id: business.id, txn_type: "inventory_purchase", amount: "-250.0",
        source: gr(receipt), financial_settlement_id: settlement.id, created_by_id: approver.id,
        notes: "Inventory Purchase - Goods Receipt #{receipt.receipt_number}"
      } ])
      expect(balance_of(custody)).to eq("750.0")

      receipt.reload
      expect([ receipt.approval_status, receipt.decided_by_id, receipt.decided_at, receipt.financial_status ])
        .to eq([ "approved", approver.id, now, "settled" ])
      audit = audits_of(receipt, "approve").sole
      expect([ audit.actor_id, audit.changes_json, audit.metadata ])
        .to eq([ approver.id, { "approval_status" => %w[pending_approval approved] }, {} ])
    end

    %w[company_cash bank_account].each do |kind|
      it "#{kind}: one full accountless settlement referencing the receipt number, no custody row" do
        receipt = pending_receipt(kind: kind)
        expect(approve(receipt)).to be_ok

        expect(settlements_of(receipt).map { fields_of(_1) }).to eq([ {
          settleable: gr(receipt), funding_source: [ nil, nil ], source_kind: kind, reference: receipt.receipt_number,
          amount: "250.0", settled_at: now, created_by_id: approver.id,
          notes: "Inventory Purchase - Goods Receipt #{receipt.receipt_number}", reverses_settlement_id: nil
        } ])
        expect(CustodyTransaction.where(source: receipt)).to be_empty
        expect(receipt.reload.financial_status).to eq("settled")
      end
    end

    it "supplier credit: nothing financial; pending settlement" do
      receipt = pending_receipt(kind: "supplier_credit")
      expect(approve(receipt)).to be_ok
      expect(settlements_of(receipt)).to be_empty
      expect(CustodyTransaction.where(source: receipt)).to be_empty
      expect(receipt.reload.financial_status).to eq("pending_settlement")
    end

    it "zero amount due (a zero-value cash or custody receipt): approved, no settlement, no custody row" do
      [ "company_cash", "employee_custody" ].each do |kind|
        receipt = pending_receipt(kind: kind, lines: [ [ product_a, 1, 0 ] ])
        expect(approve(receipt)).to be_ok
        expect(receipt.reload.approval_status).to eq("approved")
        expect(settlements_of(receipt)).to be_empty
        expect(CustodyTransaction.where(source: receipt)).to be_empty
      end
      expect(balance_of(custody)).to eq("1000.0")
    end

    it "refuses an inactive custody account: nothing written, still pending" do
      inactive = funded_custody(requester, 500, active: false)
      receipt = pending_receipt(account: inactive)

      result = approve(receipt)
      expect([ result.ok?, result.error ]).to eq([ false, I18n.t("inventory.goods_receipts.errors.no_active_custody_account") ])
      expect(receipt.reload.approval_status).to eq("pending_approval")
      expect(settlements_of(receipt)).to be_empty
      expect(custody_txns_of(inactive)).to be_empty
      expect(balance_of(inactive)).to eq("500.0")
      expect(audits_of(receipt, "approve")).to be_empty
    end

    it "refuses a second approval: one settlement, one custody debit" do
      receipt = pending_receipt
      expect(approve(receipt)).to be_ok

      second = approve(receipt)
      expect([ second.ok?, second.error ])
        .to eq([ false, I18n.t("inventory.goods_receipts.errors.invalid_approval_transition") ])
      expect(settlements_of(receipt).size).to eq(1)
      expect(custody_txns_of(custody).size).to eq(1)
      expect(balance_of(custody)).to eq("750.0")
    end

    describe "advance application (receipt from a Purchase Request with a confirmed advance)" do
      let(:request) do
        pr = PurchaseRequest.new(business: business, supplier: supplier, created_by: requester)
        pr.items.build(product: product_a, quantity: 2, unit_price: 100, source_warehouse: warehouse)
        pr.items.build(product: product_b, quantity: 1, unit_price: 50, source_warehouse: warehouse)
        pr.save!
        pr.update_column(:status, "approved")
        pr
      end

      # A company-cash advance on the request, recorded and confirmed (S2 scope: setup only).
      def confirmed_advance(amount)
        recorded = Inventory::PurchaseRequestAdvanceRecorder.new(
          purchase_request_id: request.id, actor: create(:user, :super_admin, business: business), idempotency_key: nil,
          params: { amount: amount, source_kind: "company_cash", paid_on: Date.current, reference: "DEP-1", notes: "deposit" }
        ).call
        raise "advance not recorded: #{recorded.error}" unless recorded.ok?

        confirmed = Inventory::PurchaseRequestAdvanceWorkflow.new(advance_id: recorded.advance.id, actor: payer).confirm!
        raise "advance not confirmed: #{confirmed.error}" unless confirmed.ok?

        recorded.advance.reload
      end

      it "applies the advance first (one application settlement), then debits custody for the remaining amount due" do
        advance = confirmed_advance(100)
        receipt = pending_receipt(request: request)
        expect(approve(receipt)).to be_ok

        application, payment = settlements_of(receipt)
        expect(fields_of(application)).to eq(
          settleable: gr(receipt), funding_source: [ "PurchaseRequestAdvance", advance.id ],
          source_kind: "purchase_request_advance", reference: request.request_number, amount: "100.0", settled_at: now,
          created_by_id: approver.id, notes: "Advance ##{advance.id} applied — Purchase Request #{request.request_number}",
          reverses_settlement_id: nil
        )
        expect(fields_of(payment)).to include(funding_source: [ "CustodyAccount", custody.id ], source_kind: "employee_custody",
                                              amount: "150.0", reverses_settlement_id: nil)
        expect(custody_txns_of(custody).map { fields_of_txn(_1) }).to eq([ {
          custody_account_id: custody.id, business_id: business.id, txn_type: "inventory_purchase", amount: "-150.0",
          source: gr(receipt), financial_settlement_id: payment.id, created_by_id: approver.id,
          notes: "Inventory Purchase - Goods Receipt #{receipt.receipt_number}"
        } ])
        expect(balance_of(custody)).to eq("850.0")
        expect(advance.reload.unapplied_amount).to eq(0)
        expect(audits_of(receipt, "approve").sole.metadata).to eq(
          "advance_applied" => "100.0", "amount_due" => "150.0", "advance_ids" => [ advance.id ],
          "purchase_request_id" => request.id
        )
      end

      it "an advance covering the whole receipt: only the application settlement; zero due moves no custody" do
        advance = confirmed_advance(250)
        receipt = pending_receipt(request: request)
        expect(approve(receipt)).to be_ok

        expect(settlements_of(receipt).map { fields_of(_1).values_at(:source_kind, :amount, :funding_source) })
          .to eq([ [ "purchase_request_advance", "250.0", [ "PurchaseRequestAdvance", advance.id ] ] ])
        expect(custody_txns_of(custody)).to be_empty
        expect(balance_of(custody)).to eq("1000.0")
        expect(audits_of(receipt, "approve").sole.metadata).to include("advance_applied" => "250.0", "amount_due" => "0.0")
      end
    end
  end

  # ── Later settlement ───────────────────────────────────────────────────────
  describe "GoodsReceiptSettlementRecorder" do
    let!(:payer_custody) { funded_custody(payer, 300) }
    let(:receipt) { approved_receipt(kind: "supplier_credit") }

    it "employee custody (the actor's own account): one settlement, a linked debit, the balance and the audit" do
      result = record_settlement(receipt, source_kind: "employee_custody", amount: "80", payment_date: "2026-10-20",
                                          reference: " INV-9 ", notes: " part ")
      expect(result).to be_ok

      settlement = settlements_of(receipt).sole
      expect(result.settlement).to eq(settlement)
      expect(fields_of(settlement)).to eq(
        settleable: gr(receipt), funding_source: [ "CustodyAccount", payer_custody.id ], source_kind: "employee_custody",
        reference: "INV-9", amount: "80.0", settled_at: Date.new(2026, 10, 20).in_time_zone, created_by_id: payer.id,
        notes: "part", reverses_settlement_id: nil
      )
      expect(custody_txns_of(payer_custody).map { fields_of_txn(_1) }).to eq([ {
        custody_account_id: payer_custody.id, business_id: business.id, txn_type: "inventory_purchase", amount: "-80.0",
        source: gr(receipt), financial_settlement_id: settlement.id, created_by_id: payer.id,
        notes: "Goods Receipt #{receipt.receipt_number} - Settlement ##{settlement.id}"
      } ])
      expect(balance_of(payer_custody)).to eq("220.0")
      expect(receipt.reload.financial_status).to eq("partially_settled")
      expect(audits_of(receipt, "record_settlement").sole.metadata).to eq(
        "settlement_id" => settlement.id, "amount" => "80.0", "source_kind" => "employee_custody",
        "custody_account_id" => payer_custody.id, "employee_id" => payer.id, "supplier_id" => supplier.id,
        "reference" => "INV-9"
      )
    end

    it "company cash: an accountless settlement (blank reference and notes stay nil, today's time), no custody row" do
      result = record_settlement(receipt, source_kind: "company_cash", amount: "250", reference: "", notes: "")
      expect(result).to be_ok

      expect(fields_of(settlements_of(receipt).sole)).to eq(
        settleable: gr(receipt), funding_source: [ nil, nil ], source_kind: "company_cash", reference: nil,
        amount: "250.0", settled_at: now, created_by_id: payer.id, notes: nil, reverses_settlement_id: nil
      )
      expect(custody_txns_of(payer_custody)).to be_empty
      expect(receipt.reload.financial_status).to eq("settled")
      expect(audits_of(receipt, "record_settlement").sole.metadata)
        .to include("source_kind" => "company_cash", "custody_account_id" => nil, "employee_id" => nil, "reference" => nil)
    end

    it "refuses without writing: invalid kind, non-positive amount, bad date, no own custody, over the remaining, settled" do
      t = ->(key, **opts) { I18n.t("inventory.goods_receipts.settlements.errors.#{key}", **opts) }
      no_custody_actor = create(:user, business: business)

      expect(record_settlement(receipt, source_kind: "supplier_credit", amount: "10").error).to eq(t.(:invalid_source_kind))
      expect(record_settlement(receipt, source_kind: "purchase_request_advance", amount: "10").error).to eq(t.(:invalid_source_kind))
      expect(record_settlement(receipt, source_kind: "company_cash", amount: "0").error).to eq(t.(:amount_must_be_positive))
      expect(record_settlement(receipt, source_kind: "company_cash", amount: "10", payment_date: "nope").error)
        .to eq(t.(:invalid_payment_date))
      expect(record_settlement(receipt, actor: no_custody_actor, source_kind: "employee_custody", amount: "10").error)
        .to eq(t.(:no_custody_account))
      expect(record_settlement(receipt, source_kind: "company_cash", amount: "250.01").error)
        .to eq(t.(:exceeds_remaining, remaining: "250.00"))
      expect(settlements_of(receipt)).to be_empty

      record_settlement(receipt, source_kind: "company_cash", amount: "250")
      expect(record_settlement(receipt, source_kind: "company_cash", amount: "1").error).to eq(t.(:already_settled))
      expect(settlements_of(receipt).size).to eq(1)
      expect(custody_txns_of(payer_custody)).to be_empty
    end

    it "refuses an inactive own custody account (only an active one is ever used)" do
      payer_custody.update!(active: false)
      expect(record_settlement(receipt, source_kind: "employee_custody", amount: "10").error)
        .to eq(I18n.t("inventory.goods_receipts.settlements.errors.no_custody_account"))
      expect(settlements_of(receipt)).to be_empty
    end
  end

  # ── Single reversal ────────────────────────────────────────────────────────
  describe "GoodsReceiptSettlementReverser" do
    let!(:payer_custody) { funded_custody(payer, 300) }
    let(:receipt) { approved_receipt(kind: "supplier_credit") }

    it "custody payment: an equal-and-opposite settlement, a linked custody credit, the balance restored and the audit" do
      original = record_settlement(receipt, source_kind: "employee_custody", amount: "80", reference: "INV-9", notes: "part").settlement

      result = reverse(receipt, original, actor: approver, reason: " wrong custody ")
      expect(result).to be_ok

      reversal = settlements_of(receipt).last
      expect(result.settlement).to eq(reversal)
      expect(fields_of(reversal)).to eq(
        settleable: gr(receipt), funding_source: [ "CustodyAccount", payer_custody.id ], source_kind: "employee_custody",
        reference: "INV-9", amount: "-80.0", settled_at: now, created_by_id: approver.id, notes: "wrong custody",
        reverses_settlement_id: original.id
      )
      expect(fields_of_txn(custody_txns_of(payer_custody).last)).to eq(
        custody_account_id: payer_custody.id, business_id: business.id, txn_type: "inventory_purchase_reversal",
        amount: "80.0", source: gr(receipt), financial_settlement_id: reversal.id, created_by_id: approver.id,
        notes: "Goods Receipt #{receipt.receipt_number} - Settlement ##{original.id} reversed: wrong custody"
      )
      expect(balance_of(payer_custody)).to eq("300.0")
      expect(fields_of(original.reload)).to include(amount: "80.0", reverses_settlement_id: nil) # never modified
      expect(receipt.reload.financial_status).to eq("pending_settlement")
      expect(audits_of(receipt, "reverse_settlement").sole.metadata).to eq(
        "settlement_id" => original.id, "reversal_id" => reversal.id, "amount" => "80.0",
        "source_kind" => "employee_custody", "reason" => "wrong custody", "custody_account_id" => payer_custody.id,
        "supplier_id" => supplier.id
      )
    end

    it "accountless payment: the reversal only, no custody row" do
      original = record_settlement(receipt, source_kind: "bank_account", amount: "100", reference: "TRX-1").settlement
      expect(reverse(receipt, original)).to be_ok

      expect(fields_of(settlements_of(receipt).last))
        .to include(funding_source: [ nil, nil ], source_kind: "bank_account", reference: "TRX-1", amount: "-100.0",
                    reverses_settlement_id: original.id)
      expect(CustodyTransaction.where(source: receipt)).to be_empty
      expect(audits_of(receipt, "reverse_settlement").sole.metadata).to include("custody_account_id" => nil)
    end

    it "refuses a second reversal, a reversal row, a blank reason and a voided receipt — nothing written" do
      original = record_settlement(receipt, source_kind: "employee_custody", amount: "80").settlement
      expect(reverse(receipt, original)).to be_ok
      reversal = settlements_of(receipt).last
      already = I18n.t("financial_settlements.errors.already_reversed")

      expect(reverse(receipt, original).error).to eq(already)
      expect(reverse(receipt, reversal).error).to eq(already)
      other = record_settlement(receipt, source_kind: "company_cash", amount: "10").settlement
      expect(reverse(receipt, other, reason: "  ").error)
        .to eq(I18n.t("inventory.goods_receipts.settlements.errors.reason_required"))
      expect(settlements_of(receipt).size).to eq(3)
      expect(custody_txns_of(payer_custody).size).to eq(2)
      expect(balance_of(payer_custody)).to eq("300.0")

      expect(void(receipt)).to be_ok
      expect(reverse(receipt, other).error).to eq(I18n.t("inventory.goods_receipts.settlements.errors.receipt_voided"))
    end

    it "refuses to reverse an advance application one by one" do
      request = PurchaseRequest.new(business: business, supplier: supplier, created_by: requester)
      request.items.build(product: product_a, quantity: 2, unit_price: 100, source_warehouse: warehouse)
      request.items.build(product: product_b, quantity: 1, unit_price: 50, source_warehouse: warehouse)
      request.save!
      request.update_column(:status, "approved")
      recorded = Inventory::PurchaseRequestAdvanceRecorder.new(
        purchase_request_id: request.id, actor: create(:user, :super_admin, business: business), idempotency_key: nil,
        params: { amount: 100, source_kind: "company_cash", paid_on: Date.current, reference: "DEP-1", notes: "d" }
      ).call
      Inventory::PurchaseRequestAdvanceWorkflow.new(advance_id: recorded.advance.id, actor: payer).confirm!
      with_advance = approved_receipt(kind: "supplier_credit", request: request)
      application = settlements_of(with_advance).sole

      expect(reverse(with_advance, application).error)
        .to eq(I18n.t("inventory.goods_receipts.settlements.errors.advance_application_not_reversible"))
      expect(settlements_of(with_advance)).to eq([ application ])
    end
  end

  # ── Void ───────────────────────────────────────────────────────────────────
  describe "GoodsReceiptVoider" do
    it "reverses every settlement still in effect (skipping one already reversed), crediting custody per custody reversal" do
      payer_custody = funded_custody(payer, 300)
      receipt = approved_receipt(kind: "supplier_credit")
      custody_paid = record_settlement(receipt, source_kind: "employee_custody", amount: "80").settlement
      cash_paid    = record_settlement(receipt, source_kind: "company_cash", amount: "50", reference: "C-1").settlement
      undone       = record_settlement(receipt, source_kind: "employee_custody", amount: "20").settlement
      expect(reverse(receipt, undone)).to be_ok
      before_void  = settlements_of(receipt).map(&:id)

      expect(void(receipt)).to be_ok

      reversals = settlements_of(receipt).reject { before_void.include?(_1.id) }
      note = "Settlement Reversal - Goods Receipt #{receipt.receipt_number}"
      expect(reversals.map { fields_of(_1) }).to contain_exactly(
        { settleable: gr(receipt), funding_source: [ "CustodyAccount", payer_custody.id ], source_kind: "employee_custody",
          reference: nil, amount: "-80.0", settled_at: now, created_by_id: approver.id, notes: note,
          reverses_settlement_id: custody_paid.id },
        { settleable: gr(receipt), funding_source: [ nil, nil ], source_kind: "company_cash", reference: "C-1",
          amount: "-50.0", settled_at: now, created_by_id: approver.id, notes: note, reverses_settlement_id: cash_paid.id }
      )
      custody_reversal = reversals.find { _1.reverses_settlement_id == custody_paid.id }
      expect(fields_of_txn(custody_txns_of(payer_custody).last)).to eq(
        custody_account_id: payer_custody.id, business_id: business.id, txn_type: "inventory_purchase_reversal",
        amount: "80.0", source: gr(receipt), financial_settlement_id: custody_reversal.id, created_by_id: approver.id,
        notes: "Goods Receipt Cancellation - #{receipt.receipt_number}"
      )
      expect(custody_txns_of(payer_custody).size).to eq(4) # 2 debits, 1 single reversal, 1 void reversal
      expect(balance_of(payer_custody)).to eq("300.0")
      expect(receipt.reload).to be_voided
      expect([ receipt.approval_status, receipt.voided_by_id, receipt.void_reason, receipt.financial_status ])
        .to eq([ "approved", approver.id, "wrong supplier", "pending_settlement" ])
      expect(audits_of(receipt, "void").sole.metadata).to eq("reason" => "wrong supplier")
    end

    it "approved custody receipt (unconfirmed): reverses the approval payment and restores the balance" do
      receipt = approved_receipt
      expect(void(receipt)).to be_ok

      original, reversal = settlements_of(receipt)
      expect(fields_of(reversal)).to include(amount: "-250.0", reverses_settlement_id: original.id,
                                             funding_source: [ "CustodyAccount", custody.id ])
      expect(custody_txns_of(custody).map { [ _1.txn_type, _1.amount.to_s, _1.financial_settlement_id ] })
        .to eq([ [ "inventory_purchase", "-250.0", original.id ], [ "inventory_purchase_reversal", "250.0", reversal.id ] ])
      expect(balance_of(custody)).to eq("1000.0")
    end

    it "pending receipt: no settlement to reverse; the approval is cancelled and recorded in the audit" do
      receipt = pending_receipt
      expect(void(receipt)).to be_ok
      expect(receipt.reload.approval_status).to eq("cancelled")
      expect(settlements_of(receipt)).to be_empty
      expect(audits_of(receipt, "void").sole.metadata)
        .to eq("reason" => "wrong supplier", "approval_status" => %w[pending_approval cancelled])
    end

    it "a second void is refused and writes nothing (reverse_all would find nothing left either)" do
      receipt = approved_receipt
      expect(void(receipt)).to be_ok
      counts = [ settlements_of(receipt).size, custody_txns_of(custody).size ]

      second = void(receipt)
      expect(second).not_to be_ok
      expect(second.error).to eq(receipt.errors.generate_message(:base, :already_voided))
      expect([ settlements_of(receipt).size, custody_txns_of(custody).size ]).to eq(counts)
      expect(FinancialSettlementService.reverse_all(settleable: receipt.reload, actor: approver)).to eq([])
    end
  end

  # ── Atomicity: a failure at each later write leaves nothing financial behind ──
  describe "failure injection" do
    def invalid(record_class, message = "injected failure")
      record = record_class.new
      record.errors.add(:base, message)
      ActiveRecord::RecordInvalid.new(record)
    end

    def fail_custody_rows! = allow_any_instance_of(CustodyTransaction).to receive(:save!).and_raise(invalid(CustodyTransaction))

    def fail_settlement_create!
      failed = FinancialSettlement.new.tap { _1.errors.add(:base, "settlement refused") }
      allow(FinancialSettlementService).to receive(:create)
        .and_return(FinancialSettlementService::Result.new(ok: false, settlement: failed, error: "settlement refused"))
    end

    def nothing_financial_for(receipt, *accounts, balances:)
      expect(settlements_of(receipt)).to be_empty
      expect(CustodyTransaction.where(source: receipt)).to be_empty
      expect(accounts.map { balance_of(_1) }).to eq(balances)
    end

    describe "approval" do
      it "custody row fails: no settlement, no custody row, balance and status unchanged, no approve audit" do
        receipt = pending_receipt
        fail_custody_rows!
        result = approve(receipt)

        expect([ result.ok?, result.error ]).to eq([ false, "injected failure" ])
        nothing_financial_for(receipt, custody, balances: [ "1000.0" ])
        expect(receipt.reload.approval_status).to eq("pending_approval")
        expect(audits_of(receipt, "approve")).to be_empty
      end

      it "settlement fails: nothing written, status unchanged" do
        receipt = pending_receipt(kind: "company_cash")
        fail_settlement_create!
        result = approve(receipt)

        expect([ result.ok?, result.error ]).to eq([ false, "settlement refused" ])
        nothing_financial_for(receipt, balances: [])
        expect(receipt.reload.approval_status).to eq("pending_approval")
      end

      it "receipt save fails after the payment: the settlement and custody row roll back with it" do
        receipt = pending_receipt
        allow_any_instance_of(GoodsReceipt).to receive(:save!).and_raise(invalid(GoodsReceipt, "receipt refused"))
        result = approve(receipt)

        expect([ result.ok?, result.error ]).to eq([ false, "receipt refused" ])
        nothing_financial_for(receipt, custody, balances: [ "1000.0" ])
        expect(GoodsReceipt.find(receipt.id).approval_status).to eq("pending_approval")
      end

      it "custody row fails after an advance was applied: the application rolls back too" do
        request = PurchaseRequest.new(business: business, supplier: supplier, created_by: requester)
        request.items.build(product: product_a, quantity: 2, unit_price: 100, source_warehouse: warehouse)
        request.items.build(product: product_b, quantity: 1, unit_price: 50, source_warehouse: warehouse)
        request.save!
        request.update_column(:status, "approved")
        recorded = Inventory::PurchaseRequestAdvanceRecorder.new(
          purchase_request_id: request.id, actor: create(:user, :super_admin, business: business), idempotency_key: nil,
          params: { amount: 100, source_kind: "company_cash", paid_on: Date.current, reference: "DEP-1", notes: "d" }
        ).call
        Inventory::PurchaseRequestAdvanceWorkflow.new(advance_id: recorded.advance.id, actor: payer).confirm!
        receipt = pending_receipt(request: request)

        fail_custody_rows!
        expect(approve(receipt)).not_to be_ok
        nothing_financial_for(receipt, custody, balances: [ "1000.0" ])
        expect(recorded.advance.reload.unapplied_amount).to eq(100)
      end

      it "audit write fails: swallowed — the approval and its payment still commit (AuditLoggable), no audit row" do
        receipt = pending_receipt
        allow(AuditLog).to receive(:create!).and_raise(invalid(AuditLog, "audit refused"))

        expect(approve(receipt)).to be_ok
        expect(receipt.reload.approval_status).to eq("approved")
        expect(settlements_of(receipt).size).to eq(1)
        expect(balance_of(custody)).to eq("750.0")
        expect(AuditLog.where(auditable: receipt)).to be_empty
      end
    end

    describe "later settlement" do
      let!(:payer_custody) { funded_custody(payer, 300) }
      let(:receipt) { approved_receipt(kind: "supplier_credit") }

      it "custody row fails: no settlement, balance unchanged, no audit" do
        receipt
        fail_custody_rows!
        result = record_settlement(receipt, source_kind: "employee_custody", amount: "80")

        expect([ result.ok?, result.error ]).to eq([ false, "injected failure" ])
        nothing_financial_for(receipt, payer_custody, balances: [ "300.0" ])
        expect(audits_of(receipt, "record_settlement")).to be_empty
      end

      it "settlement fails: the record's message, nothing written" do
        receipt
        fail_settlement_create!
        result = record_settlement(receipt, source_kind: "employee_custody", amount: "80")

        expect([ result.ok?, result.error ]).to eq([ false, "settlement refused" ])
        nothing_financial_for(receipt, payer_custody, balances: [ "300.0" ])
      end
    end

    describe "single reversal" do
      it "custody credit fails: no reversal row, balance stays debited, no audit" do
        payer_custody = funded_custody(payer, 300)
        receipt = approved_receipt(kind: "supplier_credit")
        original = record_settlement(receipt, source_kind: "employee_custody", amount: "80").settlement
        fail_custody_rows!
        result = reverse(receipt, original)

        expect([ result.ok?, result.error ]).to eq([ false, "injected failure" ])
        expect(settlements_of(receipt)).to eq([ original ])
        expect(balance_of(payer_custody)).to eq("220.0")
        expect(audits_of(receipt, "reverse_settlement")).to be_empty
      end
    end

    describe "void" do
      it "custody credit fails: the error propagates (not rescued by the voider) and nothing is reversed or voided" do
        receipt = approved_receipt
        fail_custody_rows!

        expect { void(receipt) }.to raise_error(ActiveRecord::RecordInvalid, /injected failure/)
        receipt.reload
        expect([ receipt.voided?, settlements_of(receipt).size, balance_of(custody) ]).to eq([ false, 1, "750.0" ])
        expect(audits_of(receipt, "void")).to be_empty
      end

      it "a reversal settlement fails: the error propagates and nothing is reversed or voided" do
        receipt = approved_receipt(kind: "company_cash")
        failed = FinancialSettlement.new.tap { _1.errors.add(:base, "reversal refused") }
        allow(FinancialSettlementService).to receive(:reverse_all)
          .and_return([ FinancialSettlementService::Result.new(ok: false, settlement: failed, error: "reversal refused") ])

        expect { void(receipt) }.to raise_error(ActiveRecord::RecordInvalid, /reversal refused/)
        expect([ receipt.reload.voided?, settlements_of(receipt).size ]).to eq([ false, 1 ])
      end
    end
  end
end
