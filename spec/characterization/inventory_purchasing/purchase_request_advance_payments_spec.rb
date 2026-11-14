require "rails_helper"

# Characterization (S2 M1) — the Finance & Sales effects of Purchase Request
# advance payments, recorded from the unchanged code (`ec8ae59`) before the
# writes move behind an Inventory & Purchasing contract
# (module-boundaries.md §14.2 #6, the half Batch S deferred to S2;
# docs/architecture/inventory-finance-purchase-request-advances-baseline-failures.txt).
#
# Pins every field the migration could change: the custody account the recorder
# accepts and the form offers; on confirmation the settlement row, the custody
# debit, the cached balance, the advance and its audit; on reversal the reversal
# settlement, the custody credit, the balance, the advance and its audit; every
# refusal message with nothing written; and the rollback when a ledger write
# fails. Concurrency is pinned separately (…_concurrency_spec.rb).
#
# Since the funding workflow (2026-11-13) every advance funds the request's
# responsible employee's custody and its confirmation posts no settlement
# (spec/services/inventory/purchase_request_advance_funding_spec.rb). What
# stays pinned here: the source account the recorder accepts and the form
# offers (every holder has the purchasing permission, a selection rule since
# then, and the request names a responsible employee, whose own account is
# never a source); that a LEGACY pending advance is refused at confirmation with
# nothing written; and the legacy supplier-payment REVERSAL, on a confirmed
# advance built in its historical shape (#legacy_confirmed_advance).
RSpec.describe "Characterization: Purchase Request advance payments (S2 M1)", type: :request do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let(:supplier)  { business.suppliers.create!(name: "Nile Beauty") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", average_cost_price: 121) }

  # 2 × 121 = 242
  let(:request_record) do
    pr = PurchaseRequest.new(business: business, supplier: supplier, created_by: owner, responsible_employee: responsible)
    pr.items.build(product: product, quantity: 2, unit_price: 121, source_warehouse: warehouse)
    pr.save!
    pr.update_column(:status, "approved")
    pr
  end

  def user_with(*permissions, first_name: nil, scopes: {})
    role = business.permission_roles.create!(name: "Role #{SecureRandom.hex(3)}", permissions: permissions,
                                             permission_scopes: scopes)
    attrs = { business: business }
    attrs[:first_name] = first_name if first_name
    create(:user, **attrs).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:recorder)  { user_with("view_inventory", "manage_purchase_request_advances", "create_purchase_requests", first_name: "Rana") }
  let(:confirmer) { user_with("view_inventory", "confirm_purchase_request_advances") }
  let(:manager) do
    user_with("view_inventory", "manage_purchase_request_advances", "confirm_purchase_request_advances",
              "view_employee_balances", "manage_employee_balances",
              scopes: { "view_employee_balances" => "business" })
  end

  def purchaser(**attrs)
    @purchaser_role ||= business.permission_roles.create!(name: "Purchaser",
                                                          permissions: %w[view_inventory create_purchase_requests])
    create(:user, business: business, **attrs).tap { |u| u.update_column(:permission_role_id, @purchaser_role.id) }
  end

  let(:employee) { purchaser(first_name: "Ahmed", last_name: "Fathy") }
  let(:custody) { funded_account(employee, 500, name: "Ahmed Float") }
  let(:responsible) { purchaser(first_name: "Mona").tap { |u| funded_account(u, 0, name: "Mona Float") } }

  def funded_account(user, amount, name:, active: true)
    create(:custody_account, business: business, user: user, name: name).tap do |account|
      account.custody_transactions.create!(business: business, txn_type: "top_up", amount: amount) if amount.nonzero?
      account.refresh_balance!
      account.update_column(:active, false) unless active
    end
  end

  def record(actor: manager, amount: 100, source_kind: "employee_custody", account: custody, reference: "DEP-1",
             paid_on: Date.new(2026, 10, 1))
    Inventory::PurchaseRequestAdvanceRecorder.new(
      purchase_request_id: request_record.id, actor: actor,
      params: { amount: amount, source_kind: source_kind, custody_account_id: account&.id,
                paid_on: paid_on, reference: reference, notes: "deposit" }
    ).call
  end

  # A confirmed advance as the pre-funding code left it (a supplier payment).
  def legacy_advance(amount: 100, source_kind: "employee_custody", account: custody)
    legacy_confirmed_advance(request: request_record, amount: amount, actor: confirmer, source_kind: source_kind,
                             custody_account: account, reference: "DEP-1", paid_on: Date.new(2026, 10, 1)).reload
  end

  def workflow(advance, actor: confirmer)
    Inventory::PurchaseRequestAdvanceWorkflow.new(advance_id: advance.id, actor: actor)
  end

  def message(key, **) = I18n.t("inventory.purchase_request_advances.errors.#{key}", **)

  def ledger_snapshot
    { settlements: FinancialSettlement.count,
      custody: CustodyTransaction.where.not(txn_type: "top_up").count,
      balance: custody.reload.current_balance,
      audits: AuditLog.where(auditable_type: "PurchaseRequestAdvance").count }
  end

  describe "custody account selection when recording (the transfer is posted at once; never a settlement)" do
    it "accepts the actor's own active account without manage_employee_balances" do
      own = funded_account(recorder, 10, name: "Rana Float")
      result = record(actor: recorder, account: own)

      expect(result).to be_ok
      expect(result.advance).to have_attributes(status: "confirmed", custody_account_id: own.id, financial_settlement_id: nil)
      expect(FinancialSettlement.count).to eq(0)
      expect(CustodyTransaction.where(custody_account: own).where.not(txn_type: "top_up").pluck(:txn_type, :amount))
        .to eq([ [ "transfer", -100 ] ])
    end

    it "refuses another employee's account without manage_employee_balances" do
      expect(record(actor: recorder, account: custody).error).to eq(message(:custody_account_required))
      expect(PurchaseRequestAdvance.count).to eq(0)
    end

    it "accepts another employee's account in scope with manage_employee_balances" do
      expect(record(actor: manager, account: custody).advance.custody_account_id).to eq(custody.id)
    end

    it "refuses an inactive account, an unknown id and a missing id" do
      inactive = funded_account(create(:user, business: business), 0, name: "Off", active: false)
      [ inactive, CustodyAccount.new(id: 999_999), nil ].each do |account|
        expect(record(actor: manager, account: account).error).to eq(message(:custody_account_required))
      end
      expect(PurchaseRequestAdvance.count).to eq(0)
    end

    it "refuses another business's account even for a business-wide balances manager" do
      foreign = create(:custody_account, business: create(:business))
      expect(record(actor: manager, account: foreign).error).to eq(message(:custody_account_required))
    end

    it "ignores the account for a company payment" do
      result = record(actor: recorder, source_kind: "company_cash", account: nil)
      expect(result.advance).to have_attributes(source_kind: "company_cash", custody_account_id: nil)
    end
  end

  describe "the form's custody options" do
    def options
      Nokogiri::HTML(response.body)
              .css("select[name='purchase_request_advance[custody_account_id]'] option")
              .map { |o| [ o.text, o["value"], o["data-balance"], o["selected"] ] }
    end

    it "lists every active account in scope, ordered, labelled with the holder and the ledger balance" do
      custody
      zed = funded_account(purchaser(first_name: "Zed", last_name: "Ali"), 0, name: "Zed Float")
      funded_account(purchaser, 30, name: "Inactive", active: false)
      sign_in manager
      get new_inventory_purchase_request_advance_path(request_record)

      # Label: custody_option(name: holder, balance: format_currency(ledger balance)) — recorded as rendered
      # for the factory business (SAR).
      blank = [ "— #{I18n.t('inventory.purchase_request_advances.select_custody_account')}", "", nil, nil ]
      # CustodyAccount.ordered is by account name: "Ahmed Float", then "Zed Float".
      expect(options.first).to eq(blank)
      expect(options.drop(1).map { |text, *rest| rest }).to eq([ [ custody.id.to_s, "500.0", nil ], [ zed.id.to_s, "0.0", nil ] ])
      expect(options.drop(1).map(&:first)).to eq([ "Ahmed Fathy — balance SAR 500.00", "Zed Ali — balance SAR 0.00" ])
    end

    it "offers only the actor's own account without manage_employee_balances, and hides Employee Custody without one" do
      own = funded_account(recorder, 0, name: "Rana Float")
      custody
      sign_in recorder
      get new_inventory_purchase_request_advance_path(request_record)
      expect(options.map(&:second).compact_blank).to eq([ own.id.to_s ])

      own.update_column(:active, false)
      get new_inventory_purchase_request_advance_path(request_record)
      expect(options.map(&:second).compact_blank).to eq([])
      kinds = Nokogiri::HTML(response.body).css("input[name='purchase_request_advance[source_kind]']").map { |i| i["value"] }
      expect(kinds).to eq(%w[company_cash bank_account])
    end

    it "re-renders the refused form with the submitted account selected" do
      custody
      sign_in manager
      post inventory_purchase_request_advances_path(request_record), params: {
        idempotency_key: SecureRandom.uuid,
        purchase_request_advance: { amount: 0, source_kind: "employee_custody", custody_account_id: custody.id,
                                    paid_on: Date.current.to_s }
      }
      expect(response).to have_http_status(:unprocessable_content)
      expect(options.find { |o| o[1] == custody.id.to_s }.last).to eq("selected")
    end
  end

  describe "a legacy pending advance" do
    it "is never executed: it can only be cancelled (with a reason), nothing financial written" do
      pending = request_record.advances.create!(business: business, amount: 100, source_kind: "employee_custody",
                                                custody_account: custody, paid_on: Date.new(2026, 10, 1),
                                                created_by: manager)
      snapshot = ledger_snapshot
      expect(workflow(pending).reverse!(reason: "x").error).to eq(message(:invalid_transition))
      expect(workflow(pending).cancel!(reason: "re-record")).to be_ok
      expect(pending.reload).to have_attributes(status: "cancelled", financial_settlement_id: nil)
      expect(ledger_snapshot.except(:audits)).to eq(snapshot.except(:audits))
    end
  end

  describe "reversal" do
    let!(:advance) { legacy_advance }
    let(:original) { advance.financial_settlement }

    it "employee custody: a reversal settlement, a linked credit, the balance restored, the advance and its audit" do
      result = workflow(advance).reverse!(reason: "  wrong supplier  ")
      expect(result).to be_ok

      reversal = FinancialSettlement.find_by!(reverses_settlement_id: original.id)
      expect(reversal).to have_attributes(
        settleable_type: "PurchaseRequest", settleable_id: request_record.id,
        funding_source_type: "CustodyAccount", funding_source_id: custody.id,
        source_kind: "employee_custody", amount: -100, created_by_id: confirmer.id, notes: "wrong supplier"
      )
      credit = CustodyTransaction.find_by!(txn_type: "inventory_purchase_reversal")
      expect(credit).to have_attributes(
        business_id: business.id, custody_account_id: custody.id, amount: 100,
        source_type: "PurchaseRequest", source_id: request_record.id, financial_settlement_id: reversal.id,
        created_by_id: confirmer.id,
        notes: I18n.t("finance.custody.purchase_request_advance_reversal_note",
                      reference: request_record.request_number, advance: advance.id, reason: "wrong supplier")
      )
      expect(CustodyTransaction.find_by!(txn_type: "inventory_purchase").voided_at).to be_nil
      expect(original.reload).to have_attributes(amount: 100, reverses_settlement_id: nil)
      expect(custody.reload.current_balance).to eq(500)

      expect(advance.reload).to have_attributes(status: "reversed", reversed_by_id: confirmer.id,
                                                reversal_reason: "wrong supplier", financial_settlement_id: original.id)
      expect(AuditLog.where(auditable: advance, action: "reverse").sole.metadata).to include(
        "settlement_id" => original.id, "reversal_id" => reversal.id, "reason" => "wrong supplier",
        "custody_account_id" => custody.id, "employee_id" => employee.id, "amount" => "100.0"
      )
    end

    it "company payment: a reversal settlement and no custody row" do
      company = legacy_advance(source_kind: "company_cash", account: nil, amount: 20)
      expect(workflow(company).reverse!(reason: "refund")).to be_ok
      expect(FinancialSettlement.where(reverses_settlement_id: company.reload.financial_settlement_id).sole)
        .to have_attributes(amount: -20, funding_source_id: nil, source_kind: "company_cash")
      expect(CustodyTransaction.where(txn_type: "inventory_purchase_reversal")).to be_empty
    end

    describe "refusals write nothing" do
      it "a blank reason, a pending advance, a second reversal" do
        pending  = request_record.advances.create!(business: business, amount: 10, source_kind: "company_cash",
                                                   paid_on: Date.current, created_by: manager)
        snapshot = ledger_snapshot
        expect(workflow(advance).reverse!(reason: "  ").error).to eq(message(:reason_required))
        expect(workflow(pending).reverse!(reason: "x").error).to eq(message(:invalid_transition))
        expect(ledger_snapshot).to eq(snapshot)

        workflow(advance).reverse!(reason: "x")
        snapshot = ledger_snapshot
        expect(workflow(advance).reverse!(reason: "again").error).to eq(message(:invalid_transition))
        expect(ledger_snapshot).to eq(snapshot)
      end

      it "an advance applied to a receipt: already_applied" do
        receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, purchase_request: request_record,
                                                received_on: Date.current, created_by: owner,
                                                funding_source_kind: "supplier_credit")
        receipt.items.build(product: product, quantity: 1, unit_cost: 121,
                            purchase_request_item: request_record.items.sole)
        receipt.save!
        receipt.update_column(:approval_status, "pending_approval")
        expect(Inventory::GoodsReceiptApproval.new(goods_receipt_id: receipt.id, actor: confirmer).approve!).to be_ok

        snapshot = ledger_snapshot
        expect(workflow(advance).reverse!(reason: "x").error).to eq(message(:already_applied))
        expect(ledger_snapshot).to eq(snapshot)
      end
    end

    it "rollback when the custody credit fails: no reversal, balance unchanged, advance confirmed" do
      snapshot = ledger_snapshot
      allow_any_instance_of(CustodyTransaction).to receive(:save!) do |txn|
        txn.errors.add(:base, "credit refused")
        raise ActiveRecord::RecordInvalid, txn
      end

      expect(workflow(advance).reverse!(reason: "x").error).to eq("credit refused")
      expect(ledger_snapshot).to eq(snapshot)
      expect(advance.reload).to be_confirmed
    end
  end
end
