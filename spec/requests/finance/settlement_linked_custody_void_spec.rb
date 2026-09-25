require "rails_helper"

RSpec.describe "Custody account page — settlement-linked transactions", type: :request do
  let(:business)  { create(:business) }
  let(:admin)     { create(:user, :super_admin, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product) do
    business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0)
  end
  let(:ahmed)   { create(:user, business: business) }
  let(:account) { create(:custody_account, business: business, user: ahmed) }
  # Balance manager with full custody rights but NO inventory access.
  let(:balance_manager) do
    create(:user, business: business,
                  permission_role: create(:permission_role, business: business,
                                                            permissions: %w[view_employee_balances manage_employee_balances],
                                                            permission_scopes: { "view_employee_balances" => "business_wide",
                                                                                 "manage_employee_balances" => "business_wide" }))
  end

  let!(:receipt) do
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current, funding_source_kind: "supplier_credit")
    r.items.build(product: product, quantity: 100, unit_cost: 50)
    r.save!
    r.update_column(:approval_status, "pending_approval")
    Inventory::GoodsReceiptApproval.new(goods_receipt_id: r.id, actor: admin).approve!
    r.reload
  end
  let!(:top_up) do
    account.custody_transactions.create!(business: business, txn_type: "top_up", amount: 10_000).tap { account.refresh_balance! }
  end
  let!(:settlement) do
    Inventory::GoodsReceiptSettlementRecorder.new(receipt.id, actor: ahmed, params: {
      source_kind: "employee_custody", amount: "5000"
    }).call.settlement
  end
  let(:debit) { settlement.custody_transaction }

  it "hides Void on the linked row, explains why, and links to the settlement; normal rows keep Void" do
    sign_in admin
    get finance_custody_account_path(account)

    expect(response).to have_http_status(:ok)
    body = response.body
    expect(body).to include(I18n.t("finance.custody.transactions.settlement_linked_hint"))
    expect(body).to include(I18n.t("finance.custody.transactions.view_settlement"))
    expect(body).to include(inventory_goods_receipt_path(receipt, anchor: "settlement-#{settlement.id}"))
    expect(body).not_to include(void_finance_custody_account_custody_transaction_path(account, debit))
    expect(body).to include(void_finance_custody_account_custody_transaction_path(account, top_up))
  end

  it "shows the explanation in Arabic" do
    admin.update!(preferred_locale: "ar")
    sign_in admin
    get finance_custody_account_path(account)

    expect(response.body).to include("عرض التسوية")
    expect(response.body).to include(I18n.t("finance.custody.transactions.settlement_linked_hint", locale: :ar))
  end

  it "omits the settlement link for a user who can't open goods receipts, but still explains" do
    sign_in balance_manager
    get finance_custody_account_path(account)

    expect(response.body).to include(I18n.t("finance.custody.transactions.settlement_linked_hint"))
    expect(response.body).not_to include(I18n.t("finance.custody.transactions.view_settlement"))
    expect(response.body).not_to include(inventory_goods_receipt_path(receipt, anchor: "settlement-#{settlement.id}"))
  end

  it "rejects a direct PATCH void request for the linked transaction (not just a hidden button)" do
    sign_in balance_manager

    patch void_finance_custody_account_custody_transaction_path(account, debit), params: { void_reason: "undo" }

    expect(response).to redirect_to(finance_custody_account_path(account))
    expect(flash[:alert]).to eq(I18n.t("finance.custody.errors.settlement_linked"))
    expect(debit.reload).not_to be_voided
    expect(account.reload.current_balance).to eq(5_000)
    expect(receipt.reload).to be_settled
  end

  it "still voids a normal custody transaction through the same endpoint" do
    sign_in balance_manager

    patch void_finance_custody_account_custody_transaction_path(account, top_up), params: { void_reason: "typo" }

    expect(flash[:notice]).to eq(I18n.t("finance.custody.transactions.voided"))
    expect(top_up.reload).to be_voided
  end
end
