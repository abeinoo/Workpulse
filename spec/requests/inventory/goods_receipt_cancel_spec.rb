require "rails_helper"

RSpec.describe "Inventory::GoodsReceipts#cancel", type: :request do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product) do
    business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0)
  end
  let(:creator_role) { create(:permission_role, business: business, permissions: %w[view_inventory create_goods_receipts]) }
  let(:creator)       { create(:user, business: business, permission_role: creator_role) }
  let(:viewer_role)  { create(:permission_role, business: business, permissions: %w[view_inventory]) }
  let(:viewer)       { create(:user, business: business, permission_role: viewer_role) }
  let(:actor)        { create(:user, :super_admin, business: business) }

  def build_receipt(approval_status: "draft", funding_source_kind: "supplier_credit", funding_source: nil)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current,
                                      funding_source_kind: funding_source_kind, funding_source: funding_source)
    r.items.build(product: product, quantity: 5, unit_cost: 10)
    r.save!
    r.update_column(:approval_status, approval_status)
    r.reload
  end

  it "lets the requester cancel a draft receipt with no inventory or financial side-effects" do
    sign_in creator
    receipt = build_receipt(approval_status: "draft")

    patch cancel_inventory_goods_receipt_path(receipt), params: { cancellation_reason: "Wrong items" }

    expect(response).to redirect_to(inventory_goods_receipt_path(receipt))
    receipt.reload
    expect(receipt).to be_voided
    expect(receipt.void_reason).to eq("Wrong items")
    expect(InventoryMovement.where(source: receipt)).to be_empty
    expect(receipt.financial_settlements).to be_empty
  end

  it "does NOT let a user without create_goods_receipts cancel" do
    sign_in viewer
    receipt = build_receipt(approval_status: "draft")

    patch cancel_inventory_goods_receipt_path(receipt), params: { cancellation_reason: "x" }

    expect(response).to redirect_to(root_path)
    expect(receipt.reload).not_to be_voided
  end

  it "does NOT allow cancelling an already-approved receipt through this action" do
    sign_in actor
    receipt = build_receipt(approval_status: "approved")

    patch cancel_inventory_goods_receipt_path(receipt), params: { cancellation_reason: "x" }

    expect(response).to redirect_to(root_path)
    expect(receipt.reload).not_to be_voided
  end

  it "reverses the custody deduction when cancelling an approved custody-funded receipt via #void instead" do
    account = create(:custody_account, business: business, user: actor)
    account.custody_transactions.create!(business: business, txn_type: "top_up", amount: 1_000)
    account.refresh_balance!
    receipt = build_receipt(approval_status: "pending_approval", funding_source_kind: "employee_custody",
                             funding_source: account)
    Inventory::GoodsReceiptApproval.new(goods_receipt_id: receipt.id, actor: actor).approve!
    expect(Finance::CustodyBalance.new(account).current).to eq(950)

    sign_in actor
    patch void_inventory_goods_receipt_path(receipt), params: { void_reason: "Approved by mistake" }

    expect(receipt.reload).to be_voided
    expect(Finance::CustodyBalance.new(account).current).to eq(1_000)
  end
end
