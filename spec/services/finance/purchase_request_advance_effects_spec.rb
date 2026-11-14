require "rails_helper"

# S2 — the Finance & Sales implementation of Inventory::PurchaseRequestAdvanceEffects,
# exercised through the contract: eligibility (source accounts, responsible
# employees), the custody rows of a funding advance and its reversal, and the
# legacy supplier-payment reversal. Behaviour through the Inventory services:
# spec/services/inventory/purchase_request_advance_funding_spec.rb and the S2
# characterization specs.
RSpec.describe Finance::PurchaseRequestAdvanceEffects do
  let(:contract)  { Inventory::PurchaseRequestAdvanceEffects }
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let(:supplier)  { business.suppliers.create!(name: "Nile Beauty") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", average_cost_price: 121) }

  def user_with(*permissions, scopes: {})
    role = business.permission_roles.create!(name: "Role #{SecureRandom.hex(3)}", permissions: permissions,
                                             permission_scopes: scopes)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:plain)   { user_with("view_inventory", "manage_purchase_request_advances", "create_purchase_requests") }
  let(:manager) do
    user_with("view_inventory", "manage_purchase_request_advances", "view_employee_balances", "manage_employee_balances",
              scopes: { "view_employee_balances" => "business" })
  end
  let(:ahmed)  { purchaser_with_custody(business, first_name: "Ahmed", last_name: "Fathy", balance: 500) }
  let(:mona)   { purchaser_with_custody(business, first_name: "Mona", last_name: "Ali", balance: 200) }
  let(:custody)      { custody_of(ahmed) }
  let(:mona_custody) { custody_of(mona) }

  let(:request_record) do
    pr = business.purchase_requests.build(warehouse: warehouse, created_by: owner, responsible_employee: mona)
    pr.items.build(product: product, quantity: 2, unit_price: 121, supplier: supplier)
    pr.save!
    pr.update_column(:status, "approved")
    pr
  end

  def funding_advance(source_kind: "company_cash", source: nil, amount: 100, reference: "TRX-9")
    request_record.advances.create!(business: business, amount: amount, source_kind: source_kind, custody_account: source,
                                    recipient_custody_account: mona_custody, paid_on: Date.new(2026, 10, 1),
                                    reference: reference, created_by: owner)
  end

  def confirm(advance)
    funding = contract.advance_funded(advance: advance, actor: owner)
    advance.update!(status: "confirmed", funding_transaction_id: funding.transaction_id)
    funding
  end

  it "is the registered handler" do
    expect(contract.handler).to equal(described_class)
  end

  describe "custody_account_options / selectable_custody_account_id (funding sources)" do
    it "without manage_employee_balances: only the actor's own active account" do
      own = create(:custody_account, business: business, user: plain, name: "A Float")
      custody
      expect(contract.custody_account_options(actor: plain))
        .to eq([ contract::CustodyAccountOption.new(id: own.id, holder_name: plain.full_name, balance: 0) ])
      expect(contract.selectable_custody_account_id(actor: plain, custody_account_id: own.id)).to eq(own.id)
      expect(contract.selectable_custody_account_id(actor: plain, custody_account_id: custody.id)).to be_nil
    end

    it "with manage_employee_balances: every eligible active account in scope, by name, with ledger balances" do
      custody
      mona_custody
      create(:custody_account, business: business, user: create(:user, business: business), name: "B No Permission")
      create(:custody_account, business: business, name: "Off", active: false)
      options = contract.custody_account_options(actor: manager)
      expect(options.map(&:id)).to eq([ custody.id, mona_custody.id ])
      expect(options.map(&:balance)).to eq([ 500, 200 ])
      expect(options.first.holder_name).to eq("Ahmed Fathy")
      expect(contract.selectable_custody_account_id(actor: manager, custody_account_id: custody.id.to_s)).to eq(custody.id)
    end

    it "never selects an ineligible, inactive, unknown, blank or foreign account" do
      no_permission = create(:custody_account, business: business, user: create(:user, business: business))
      inactive_user = custody_of(purchaser_with_custody(business)).tap { |a| a.user.update_column(:active, false) }
      inactive      = create(:custody_account, business: business, active: false)
      foreign       = create(:custody_account, business: create(:business))
      [ no_permission.id, inactive_user.id, inactive.id, foreign.id, 999_999, nil, "" ].each do |id|
        expect(contract.selectable_custody_account_id(actor: manager, custody_account_id: id)).to be_nil
      end
    end
  end

  describe "responsible_employee_options / responsible_custody_account_id" do
    it "lists every eligible employee of the business with their account and balance, without custody visibility" do
      ahmed
      mona
      create(:custody_account, business: business, user: create(:user, business: business), name: "No Permission")
      custody_of(purchaser_with_custody(business, first_name: "Off")).update_column(:active, false)

      expect(contract.responsible_employee_options(actor: plain)).to eq([
        contract::ResponsibleEmployeeOption.new(user_id: ahmed.id, name: "Ahmed Fathy", custody_account_id: custody.id, balance: 500),
        contract::ResponsibleEmployeeOption.new(user_id: mona.id, name: "Mona Ali", custody_account_id: mona_custody.id, balance: 200)
      ])
    end

    it "returns the eligible employee's active account id, otherwise nil" do
      no_permission = create(:user, business: business).tap { |u| create(:custody_account, business: business, user: u) }
      no_account    = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, purchaser_role_for(business).id) }
      expect(contract.responsible_custody_account_id(business_id: business.id, user_id: mona.id)).to eq(mona_custody.id)
      [ no_permission.id, no_account.id, 999_999, nil ].each do |id|
        expect(contract.responsible_custody_account_id(business_id: business.id, user_id: id)).to be_nil
      end
      expect(contract.responsible_custody_account_id(business_id: create(:business).id, user_id: mona.id)).to be_nil
    end
  end

  describe "advance_funded" do
    it "employee transfer: one linked pair (source −, responsible +); returns the credit and the source debit" do
      funding = contract.advance_funded(advance: funding_advance(source_kind: "employee_custody", source: custody), actor: owner)

      expect(funding).to be_confirmed
      credit = CustodyTransaction.find(funding.transaction_id)
      debit  = CustodyTransaction.find(funding.counterparty_id)
      expect(credit).to have_attributes(txn_type: "transfer", custody_account_id: mona_custody.id, amount: 100,
                                        source: request_record, transfer_counterparty_id: debit.id,
                                        financial_settlement_id: nil, created_by_id: owner.id)
      expect(debit).to have_attributes(txn_type: "transfer", custody_account_id: custody.id, amount: -100,
                                       source: request_record, transfer_counterparty_id: credit.id)
      expect(credit.notes).to include(request_record.request_number, "Ahmed Fathy", "Mona Ali")
      expect(FinancialSettlement.count).to eq(0)
      expect([ custody.reload.current_balance, mona_custody.reload.current_balance ]).to eq([ 400, 300 ])
    end

    %w[company_cash bank_account].each do |kind|
      it "#{kind}: one purchase_advance_funding credit on the responsible custody, the method and reference in the note" do
        funding = contract.advance_funded(advance: funding_advance(source_kind: kind), actor: owner)

        credit = CustodyTransaction.find(funding.transaction_id)
        expect(funding.counterparty_id).to be_nil
        expect(credit).to have_attributes(txn_type: "purchase_advance_funding", custody_account_id: mona_custody.id,
                                          amount: 100, source: request_record, transfer_counterparty_id: nil,
                                          financial_settlement_id: nil)
        expect(credit.notes).to include(I18n.t("finance.custody.advance_funding_methods.#{kind}"), "TRX-9",
                                        request_record.request_number)
        expect(FinancialSettlement.count).to eq(0)
        expect(mona_custody.reload.current_balance).to eq(300)
      end
    end

    it "an inactive account: :custody_account_inactive, nothing written" do
      [ custody, mona_custody ].each do |account|
        advance = funding_advance(source_kind: "employee_custody", source: custody)
        account.update_column(:active, false)
        expect(contract.advance_funded(advance: advance, actor: owner))
          .to eq(contract::Funding.new(status: :custody_account_inactive))
        account.update_column(:active, true)
      end
      expect(CustodyTransaction.where.not(txn_type: "top_up")).to be_empty
    end

    it "an employee who lost the permission or was deactivated: :employee_ineligible, nothing written" do
      advance = funding_advance(source_kind: "employee_custody", source: custody)
      ahmed.update_column(:permission_role_id, nil)
      expect(contract.advance_funded(advance: advance, actor: owner)).to eq(contract::Funding.new(status: :employee_ineligible))

      company = funding_advance
      mona.update_column(:active, false)
      expect(contract.advance_funded(advance: company, actor: owner)).to eq(contract::Funding.new(status: :employee_ineligible))
      expect(CustodyTransaction.where.not(txn_type: "top_up")).to be_empty
    end
  end

  describe "advance_funding_reversed" do
    it "employee transfer: the opposite linked pair, both balances restored, originals untouched" do
      advance  = funding_advance(source_kind: "employee_custody", source: custody)
      original = confirm(advance)

      reversal = contract.advance_funding_reversed(advance: advance, actor: owner, reason: "refund")
      expect(CustodyTransaction.find(reversal.transaction_id))
        .to have_attributes(txn_type: "transfer", custody_account_id: mona_custody.id, amount: -100,
                            transfer_counterparty_id: reversal.counterparty_id)
      expect(CustodyTransaction.find(reversal.counterparty_id)).to have_attributes(custody_account_id: custody.id, amount: 100)
      expect(CustodyTransaction.find(original.transaction_id)).to have_attributes(amount: 100, voided_at: nil)
      expect([ custody.reload.current_balance, mona_custody.reload.current_balance ]).to eq([ 500, 200 ])
    end

    it "company funding: one purchase_advance_funding_reversal debit, even on an account made inactive since" do
      advance = funding_advance
      confirm(advance)
      mona_custody.update_column(:active, false)

      reversal = contract.advance_funding_reversed(advance: advance, actor: owner, reason: "refund")
      expect(reversal.counterparty_id).to be_nil
      expect(CustodyTransaction.find(reversal.transaction_id))
        .to have_attributes(txn_type: "purchase_advance_funding_reversal", custody_account_id: mona_custody.id, amount: -100)
      expect(mona_custody.reload.current_balance).to eq(200)
    end
  end

  describe "advance_reversed (legacy supplier payment)" do
    it "custody: reversal settlement + linked credit; returns both ids" do
      legacy = legacy_confirmed_advance(request: request_record, amount: 100, actor: owner,
                                        source_kind: "employee_custody", custody_account: custody)
      settlement_id = legacy.financial_settlement_id

      reversal = contract.advance_reversed(advance: legacy, actor: owner, reason: "refund")
      expect(reversal.settlement_id).to eq(settlement_id)
      expect(FinancialSettlement.find(reversal.reversal_id))
        .to have_attributes(reverses_settlement_id: settlement_id, amount: -100, notes: "refund")
      expect(CustodyTransaction.find_by!(txn_type: "inventory_purchase_reversal").amount).to eq(100)
      expect(custody.reload.current_balance).to eq(500)
    end

    it "a second reversal of the same settlement raises RecordInvalid (the caller rolls back)" do
      legacy = legacy_confirmed_advance(request: request_record, amount: 50, actor: owner)
      contract.advance_reversed(advance: legacy, actor: owner, reason: "once")
      expect { contract.advance_reversed(advance: legacy.reload, actor: owner, reason: "twice") }
        .to raise_error(ActiveRecord::RecordInvalid)
    end
  end
end
