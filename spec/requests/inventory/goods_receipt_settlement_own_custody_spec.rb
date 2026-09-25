require "rails_helper"

# Employee Custody on the settlement form ALWAYS means the logged-in user's own
# custody account, resolved server-side — no selector, and no account id is
# ever taken from the request.
RSpec.describe "Goods receipt settlement — Employee Custody is the current user's own", type: :request do
  let(:business) { create(:business) }
  let(:approver_role) do
    create(:permission_role, business: business, permissions: %w[view_inventory approve_goods_receipts])
  end
  let(:ahmed)   { create(:user, business: business, permission_role: approver_role) } # logged in
  let(:mohamed) { create(:user, business: business) }                                  # someone else
  let(:admin)   { create(:user, :super_admin, business: business) }                    # no custody account

  let!(:ahmed_account)   { custody_for(ahmed, 14_027.32) }
  let!(:mohamed_account) { custody_for(mohamed, 50_000) }

  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product) do
    business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0)
  end
  let!(:receipt) do # 20,000 remaining
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current, funding_source_kind: "supplier_credit")
    r.items.build(product: product, quantity: 400, unit_cost: 50)
    r.save!
    r.update_column(:approval_status, "pending_approval")
    Inventory::GoodsReceiptApproval.new(goods_receipt_id: r.id, actor: admin).approve!
    r.reload
  end

  def custody_for(user, amount)
    account = create(:custody_account, business: business, user: user)
    account.custody_transactions.create!(business: business, txn_type: "top_up", amount: amount)
    account.refresh_balance!
    account
  end

  def pay(amount, **extra)
    post inventory_goods_receipt_settlements_path(receipt), params: {
      settlement: { source_kind: "employee_custody", amount: amount.to_s, payment_date: Date.current.to_s }.merge(extra)
    }
  end

  def t_s(key, **) = I18n.t("inventory.goods_receipts.settlements.#{key}", **)

  describe "the form" do
    it "shows the logged-in user's own custody balance and no employee selector" do
      sign_in ahmed
      get new_inventory_goods_receipt_settlement_path(receipt)

      html = Nokogiri::HTML(response.body)
      expect(response.body).to include(t_s("custody_balance"))
      expect(response.body).to include("SAR 14,027.32")
      expect(response.body).not_to include("50,000.00")                  # never another employee's balance
      expect(html.css("select")).to be_empty
      expect(html.css("[name*='custody_account'], [name*='employee']")).to be_empty
      expect(html.at_css("form")["data-settlement-form-balance-value"]).to eq("14027.32")
      expect(html.at_css("form")["data-settlement-form-has-custody-value"]).to eq("true")
    end

    it "explains and flags 'no custody' for a user without an active custody account (e.g. super admin)" do
      sign_in admin
      get new_inventory_goods_receipt_settlement_path(receipt)

      html = Nokogiri::HTML(response.body)
      expect(response.body).to include(CGI.escapeHTML(t_s("errors.no_custody_account")))
      expect(html.at_css("form")["data-settlement-form-has-custody-value"]).to eq("false")
      expect(response.body).not_to include("50,000.00")
      expect(response.body).not_to include("14,027.32")
    end
  end

  describe "recording" do
    before { sign_in ahmed }

    it "debits the logged-in user's custody — recorder and custody owner are the same person" do
      pay(5_000)

      expect(response).to redirect_to(inventory_goods_receipt_path(receipt))
      settlement = receipt.financial_settlements.sole
      expect(settlement.funding_source).to eq(ahmed_account)
      expect(settlement.created_by).to eq(ahmed)
      expect(settlement.custody_transaction.custody_account).to eq(ahmed_account)
      expect(ahmed_account.reload.current_balance).to eq(9_027.32)
      expect(mohamed_account.reload.current_balance).to eq(50_000)
    end

    it "ignores a custody_account_id / employee_id smuggled into the request" do
      pay(1_000, custody_account_id: mohamed_account.id, employee_id: mohamed.id, user_id: mohamed.id,
                 balance: "999999", available_balance: "999999")

      expect(response).to redirect_to(inventory_goods_receipt_path(receipt))
      expect(receipt.financial_settlements.sole.funding_source).to eq(ahmed_account)
      expect(ahmed_account.reload.current_balance).to eq(13_027.32)
      expect(mohamed_account.reload.current_balance).to eq(50_000)
      expect(mohamed_account.custody_transactions.of_type("inventory_purchase")).to be_empty
    end

    it "accepts an amount exactly equal to the user's balance" do
      pay("14027.32")

      expect(response).to redirect_to(inventory_goods_receipt_path(receipt))
      expect(ahmed_account.reload.current_balance).to eq(0)
    end

    it "allows an amount above the user's balance — custody goes negative, the full amount is recorded" do
      pay(20_000)

      expect(response).to redirect_to(inventory_goods_receipt_path(receipt))
      settlement = receipt.financial_settlements.sole
      expect(settlement.custody_transaction.amount).to eq(-20_000)
      expect(ahmed_account.reload.current_balance).to eq(-5_972.68)
      expect(mohamed_account.reload.current_balance).to eq(50_000)
    end

    it "rejects an amount above the receipt's remaining amount even when the balance covers it" do
      ahmed_account.custody_transactions.create!(business: business, txn_type: "top_up", amount: 20_000)
      ahmed_account.refresh_balance!

      pay(20_000.01)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(receipt.financial_settlements).to be_empty
    end

    it "never shows an insufficient-balance error (Arabic)" do
      ahmed.update!(preferred_locale: "ar")
      pay(20_000)

      expect(response).to redirect_to(inventory_goods_receipt_path(receipt))
      follow_redirect!
      expect(response.body).not_to include("غير كافٍ")
      expect(response.body).to include(I18n.t("inventory.goods_receipts.settlements.recorded", locale: :ar))
    end

    it "still rejects a zero or negative amount" do
      pay(0)
      expect(response).to have_http_status(:unprocessable_entity)
      pay(-50)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(receipt.financial_settlements).to be_empty
    end
  end

  it "rejects Employee Custody for a user with no custody account, never falling back to someone else's" do
    sign_in admin

    post inventory_goods_receipt_settlements_path(receipt), params: {
      settlement: { source_kind: "employee_custody", amount: "100", custody_account_id: mohamed_account.id }
    }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include(CGI.escapeHTML(t_s("errors.no_custody_account")))
    expect(receipt.financial_settlements).to be_empty
    expect(mohamed_account.reload.current_balance).to eq(50_000)
  end

  it "rejects when the user's custody account is inactive" do
    ahmed_account.update!(active: false)
    sign_in ahmed

    pay(100)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include(CGI.escapeHTML(t_s("errors.no_custody_account")))
    expect(receipt.financial_settlements).to be_empty
  end

  it "FINAL SCENARIO: balance 1,000, receipt remaining 2,000, pay 2,000 → −1,000; reverse → 1,000" do
    user = create(:user, business: business, permission_role: approver_role)
    account = custody_for(user, 1_000)
    small = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current, funding_source_kind: "supplier_credit")
    small.items.build(product: product, quantity: 40, unit_cost: 50) # 2,000
    small.save!
    small.update_column(:approval_status, "pending_approval")
    Inventory::GoodsReceiptApproval.new(goods_receipt_id: small.id, actor: admin).approve!
    small.reload
    expect(small.remaining_settlement_amount).to eq(2_000)
    sign_in user

    post inventory_goods_receipt_settlements_path(small), params: {
      settlement: { source_kind: "employee_custody", amount: "2000", payment_date: Date.current.to_s }
    }

    expect(response).to redirect_to(inventory_goods_receipt_path(small))     # no validation error
    expect(flash[:alert]).to be_nil
    settlement = small.financial_settlements.sole
    expect(settlement.custody_transaction.amount).to eq(-2_000)
    expect(settlement.custody_transaction.custody_account).to eq(account)
    expect(account.reload.current_balance).to eq(-1_000)
    expect(account.computed_balance).to eq(-1_000)
    small.reload
    expect(small.total_settled_amount).to eq(2_000)                         # paid +2,000
    expect(small.remaining_settlement_amount).to eq(0)                      # remaining −2,000
    expect(small).to be_settled

    result = Inventory::GoodsReceiptSettlementReverser.new(goods_receipt_id: small.id, settlement_id: settlement.id,
                                                           actor: admin, reason: "Reverse").call
    expect(result).to be_ok
    expect(account.reload.current_balance).to eq(1_000)
    expect(small.reload.remaining_settlement_amount).to eq(2_000)
  end

  it "reversal restores the amount to the same user's custody" do
    sign_in ahmed
    pay(5_000)
    settlement = receipt.financial_settlements.sole
    expect(ahmed_account.reload.current_balance).to eq(9_027.32)

    result = Inventory::GoodsReceiptSettlementReverser.new(goods_receipt_id: receipt.id, settlement_id: settlement.id,
                                                           actor: admin, reason: "Mistake").call

    expect(result).to be_ok
    expect(ahmed_account.reload.current_balance).to eq(14_027.32)
    expect(mohamed_account.reload.current_balance).to eq(50_000)
    expect(settlement.reload.reversal.custody_transaction.custody_account).to eq(ahmed_account)
  end
end
