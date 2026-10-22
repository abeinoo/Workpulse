require "rails_helper"

# S2 — the Finance & Sales implementation of Inventory::PurchaseRequestAdvanceEffects,
# exercised through the contract. Field-level behaviour through the Inventory
# services is pinned by
# spec/characterization/inventory_purchasing/purchase_request_advance_payments_spec.rb;
# this spec proves each operation on its own, including business isolation.
RSpec.describe Finance::PurchaseRequestAdvanceEffects do
  let(:contract)  { Inventory::PurchaseRequestAdvanceEffects }
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let(:supplier)  { business.suppliers.create!(name: "Nile Beauty") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", average_cost_price: 121) }
  let(:request_record) do
    pr = PurchaseRequest.new(business: business, supplier: supplier, created_by: owner)
    pr.items.build(product: product, quantity: 2, unit_price: 121, source_warehouse: warehouse)
    pr.save!
    pr.update_column(:status, "approved")
    pr
  end

  def user_with(*permissions, scopes: {})
    role = business.permission_roles.create!(name: "Role #{SecureRandom.hex(3)}", permissions: permissions,
                                             permission_scopes: scopes)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:plain)   { user_with("view_inventory", "manage_purchase_request_advances") }
  let(:manager) do
    user_with("view_inventory", "manage_purchase_request_advances", "view_employee_balances", "manage_employee_balances",
              scopes: { "view_employee_balances" => "business" })
  end
  let(:employee) { create(:user, business: business, first_name: "Ahmed", last_name: "Fathy") }
  let(:custody) do
    create(:custody_account, business: business, user: employee, name: "B Float").tap do |account|
      account.custody_transactions.create!(business: business, txn_type: "top_up", amount: 500)
      account.refresh_balance!
    end
  end

  def advance(source_kind: "employee_custody", account: custody, amount: 100)
    request_record.advances.create!(business: business, amount: amount, source_kind: source_kind, custody_account: account,
                                    paid_on: Date.new(2026, 10, 1), reference: "DEP-1", created_by: owner)
  end

  it "is the registered handler" do
    expect(contract.handler).to equal(described_class)
  end

  describe "custody_account_options / selectable_custody_account_id" do
    it "without manage_employee_balances: only the actor's own active account" do
      own = create(:custody_account, business: business, user: plain, name: "A Float")
      custody
      expect(contract.custody_account_options(actor: plain))
        .to eq([ contract::CustodyAccountOption.new(id: own.id, holder_name: plain.full_name, balance: 0) ])
      expect(contract.selectable_custody_account_id(actor: plain, custody_account_id: own.id)).to eq(own.id)
      expect(contract.selectable_custody_account_id(actor: plain, custody_account_id: custody.id)).to be_nil
    end

    it "with manage_employee_balances: every active account in scope, by name, with ledger balances" do
      custody
      other = create(:custody_account, business: business, user: create(:user, business: business), name: "A Float")
      create(:custody_account, business: business, name: "Off", active: false)
      options = contract.custody_account_options(actor: manager)
      expect(options.map(&:id)).to eq([ other.id, custody.id ])
      expect(options.map(&:balance)).to eq([ 0, 500 ])
      expect(options.last.holder_name).to eq("Ahmed Fathy")
      expect(contract.selectable_custody_account_id(actor: manager, custody_account_id: custody.id.to_s)).to eq(custody.id)
    end

    it "never selects an inactive, unknown, blank or foreign account" do
      inactive = create(:custody_account, business: business, active: false)
      foreign  = create(:custody_account, business: create(:business))
      [ inactive.id, foreign.id, 999_999, nil, "" ].each do |id|
        expect(contract.selectable_custody_account_id(actor: manager, custody_account_id: id)).to be_nil
      end
    end
  end

  describe "advance_confirmed" do
    it "custody: settlement + linked debit + refreshed balance; returns its id" do
      a = advance
      confirmation = contract.advance_confirmed(advance: a, actor: owner)
      settlement = FinancialSettlement.find(confirmation.settlement_id)
      expect(confirmation).to be_confirmed
      expect(settlement).to have_attributes(settleable: request_record, funding_source: custody, amount: 100,
                                            source_kind: "employee_custody", reference: "DEP-1")
      expect(settlement.custody_transaction).to have_attributes(txn_type: "inventory_purchase", amount: -100)
      expect(custody.reload.current_balance).to eq(400)
    end

    it "company payment: an accountless settlement only" do
      confirmation = contract.advance_confirmed(advance: advance(source_kind: "company_cash", account: nil), actor: owner)
      expect(FinancialSettlement.find(confirmation.settlement_id).funding_source_id).to be_nil
      expect(CustodyTransaction.where.not(txn_type: "top_up")).to be_empty
    end

    it "an inactive account: :custody_account_inactive and nothing written" do
      a = advance
      custody.update_column(:active, false)
      expect(contract.advance_confirmed(advance: a, actor: owner))
        .to eq(contract::Confirmation.new(status: :custody_account_inactive))
      expect(FinancialSettlement.count).to eq(0)
    end
  end

  describe "advance_reversed" do
    it "custody: reversal settlement + linked credit; returns both ids" do
      a = advance
      settlement_id = contract.advance_confirmed(advance: a, actor: owner).settlement_id
      a.update!(status: "confirmed", financial_settlement_id: settlement_id)

      reversal = contract.advance_reversed(advance: a, actor: owner, reason: "refund")
      expect(reversal.settlement_id).to eq(settlement_id)
      expect(FinancialSettlement.find(reversal.reversal_id))
        .to have_attributes(reverses_settlement_id: settlement_id, amount: -100, notes: "refund")
      expect(CustodyTransaction.find_by!(txn_type: "inventory_purchase_reversal").amount).to eq(100)
      expect(custody.reload.current_balance).to eq(500)
    end

    it "a second reversal of the same settlement raises RecordInvalid (the caller rolls back)" do
      a = advance
      a.update!(status: "confirmed",
                financial_settlement_id: contract.advance_confirmed(advance: a, actor: owner).settlement_id)
      contract.advance_reversed(advance: a, actor: owner, reason: "once")
      expect { contract.advance_reversed(advance: a.reload, actor: owner, reason: "twice") }
        .to raise_error(ActiveRecord::RecordInvalid)
    end
  end
end
