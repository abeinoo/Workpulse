require "rails_helper"

RSpec.describe "Goods receipt show page — status card & activity timeline", type: :request do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product) do
    business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0)
  end
  let!(:account) { create(:custody_account, business: business, user: owner) }

  before { sign_in owner }

  def top_up!(amount)
    account.custody_transactions.create!(business: business, txn_type: "top_up", amount: amount)
    account.refresh_balance!
  end

  def create_custody_receipt(qty: 10, cost: 50)
    post inventory_goods_receipts_path, params: {
      goods_receipt: {
        warehouse_id: warehouse.id, received_on: Date.current, funding_source_kind: "employee_custody",
        items_attributes: { "0" => { product_id: product.id, quantity: qty, unit_cost: cost } }
      }
    }
    business.goods_receipts.order(:created_at).last
  end

  it "shows the current-status card with all three independent statuses at draft" do
    receipt = create_custody_receipt
    get inventory_goods_receipt_path(receipt)

    expect(response.body).to include(I18n.t("inventory.goods_receipts.current_status"))
    expect(response.body).to include(I18n.t("inventory.goods_receipts.approval_statuses.draft"))
    expect(response.body).to include(I18n.t("inventory.goods_receipts.receipt_statuses.not_received"))
    expect(response.body).to include(I18n.t("inventory.goods_receipts.financial_statuses.pending_settlement"))
  end

  it "builds a chronological activity timeline through the full approve → confirm lifecycle, with the financial settlement event" do
    top_up!(1000)
    receipt = create_custody_receipt(qty: 10, cost: 50)

    post submit_inventory_goods_receipt_path(receipt)
    post approve_inventory_goods_receipt_path(receipt) # owner bypasses self-approval
    post confirm_inventory_goods_receipt_path(receipt)

    get inventory_goods_receipt_path(receipt)

    body = response.body
    expect(body).to include(I18n.t("inventory.goods_receipts.activity_timeline"))
    expect(body).to include(I18n.t("inventory.goods_receipts.timeline.created"))
    expect(body).to include(I18n.t("inventory.goods_receipts.timeline.submitted"))
    expect(body).to include(I18n.t("inventory.goods_receipts.timeline.approved"))
    expect(body).to include(I18n.t("inventory.goods_receipts.timeline.settled"))
    expect(body).to include(I18n.t("inventory.goods_receipts.timeline.received"))
    expect(body).not_to include(I18n.t("inventory.goods_receipts.timeline.voided"))

    # Chronological order: created appears before the terminal "received" event.
    expect(body.index(I18n.t("inventory.goods_receipts.timeline.created")))
      .to be < body.index(I18n.t("inventory.goods_receipts.timeline.received"))

    expect(response.body).to include(I18n.t("inventory.goods_receipts.custody_transaction_reference"))
    expect(response.body).to include(I18n.t("inventory.goods_receipts.financial_settlement_reference"))
  end

  it "shows the voided event and hides every workflow action once voided" do
    top_up!(1000)
    receipt = create_custody_receipt(qty: 10, cost: 50)
    post submit_inventory_goods_receipt_path(receipt)
    post approve_inventory_goods_receipt_path(receipt)
    patch void_inventory_goods_receipt_path(receipt), params: { void_reason: "wrong supplier" }

    get inventory_goods_receipt_path(receipt)

    expect(response.body).to include(I18n.t("inventory.goods_receipts.timeline.voided"))
    expect(response.body).to include(I18n.t("inventory.goods_receipts.receipt_statuses.voided"))
    expect(response.body).not_to include(I18n.t("inventory.goods_receipts.edit_action"))
    expect(response.body).not_to include(I18n.t("inventory.goods_receipts.submit_for_approval"))
    expect(response.body).not_to include(I18n.t("inventory.goods_receipts.confirm"))
  end

  it "hides custody-specific payment fields for a supplier-credit receipt" do
    post inventory_goods_receipts_path, params: {
      goods_receipt: {
        warehouse_id: warehouse.id, received_on: Date.current, funding_source_kind: "supplier_credit",
        items_attributes: { "0" => { product_id: product.id, quantity: 1, unit_cost: 10 } }
      }
    }
    receipt = business.goods_receipts.order(:created_at).last

    get inventory_goods_receipt_path(receipt)

    expect(response.body).to include(I18n.t("inventory.goods_receipts.payment_information"))
    expect(response.body).not_to include(I18n.t("inventory.goods_receipts.custody_account"))
    expect(response.body).not_to include(I18n.t("inventory.goods_receipts.custody_transaction_reference"))
  end
end
