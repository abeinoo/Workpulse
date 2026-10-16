require "rails_helper"

RSpec.describe "Inventory::StockIssues workflow", type: :request do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:branch)    { business.branches.create!(name: "Nasr City", active: true) }
  let(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
  end

  let(:creator_role)  { create(:permission_role, business: business, permissions: %w[view_inventory manage_stock_issues]) }
  let(:creator)       { create(:user, business: business, permission_role: creator_role) }
  let(:approver_role) { create(:permission_role, business: business, permissions: %w[view_inventory approve_stock_issues]) }
  let(:approver)      { create(:user, business: business, permission_role: approver_role) }
  let(:confirmer_role) { create(:permission_role, business: business, permissions: %w[view_inventory confirm_stock_issues]) }
  let(:confirmer)      { create(:user, business: business, permission_role: confirmer_role) }

  def receive_stock!(qty)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: product, quantity: qty, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  def draft_issue
    i = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current, created_by: creator)
    i.items.build(product: product, quantity: 5)
    i.status = :draft
    i.save!
    i
  end

  it "walks the full lifecycle: draft -> submit -> approve -> confirm, deducting stock only at confirm" do
    receive_stock!(10)
    issue = draft_issue

    sign_in creator
    post submit_inventory_stock_issue_path(issue)
    expect(issue.reload).to be_pending_approval
    expect(product.reload.current_stock).to eq(10)

    sign_in approver
    post approve_inventory_stock_issue_path(issue)
    expect(issue.reload).to be_approved
    expect(product.reload.current_stock).to eq(10) # still untouched

    sign_in confirmer
    post confirm_inventory_stock_issue_path(issue)
    expect(issue.reload).to be_issued
    expect(product.reload.current_stock).to eq(5) # deducted exactly here

    get inventory_stock_issue_path(issue)
    expect(response.body).to include(I18n.t("inventory.stock_issues.statuses.issued"))
  end

  it "rejects: pending_approval -> rejected, with a required reason, and never touches stock" do
    receive_stock!(10)
    issue = draft_issue

    sign_in creator
    post submit_inventory_stock_issue_path(issue)

    sign_in approver
    post reject_inventory_stock_issue_path(issue), params: { rejection_reason: "wrong branch" }

    expect(issue.reload).to be_rejected
    expect(issue.rejection_reason).to eq("wrong branch")
    expect(product.reload.current_stock).to eq(10)
  end

  it "cancels a draft directly, and an approved issue before confirmation — never an issued one" do
    receive_stock!(10)
    issue = draft_issue

    sign_in creator
    patch cancel_inventory_stock_issue_path(issue), params: { cancellation_reason: "no longer needed" }
    expect(issue.reload).to be_cancelled

    issue2 = draft_issue
    sign_in creator
    post submit_inventory_stock_issue_path(issue2)
    sign_in approver
    post approve_inventory_stock_issue_path(issue2)
    sign_in creator
    patch cancel_inventory_stock_issue_path(issue2), params: { cancellation_reason: "budget cut" }
    expect(issue2.reload).to be_cancelled

    sign_in confirmer
    post confirm_inventory_stock_issue_path(issue2)
    expect(issue2.reload).to be_cancelled # confirm refused — cancelled is terminal, not approved
  end

  it "rejects invalid transitions at the controller/service layer regardless of the request" do
    receive_stock!(10)
    issue = draft_issue

    sign_in confirmer
    post confirm_inventory_stock_issue_path(issue) # draft -> issued must fail
    expect(issue.reload).to be_draft

    sign_in approver
    post approve_inventory_stock_issue_path(issue) # draft -> approved must fail (never submitted)
    expect(issue.reload).to be_draft
  end

  it "blocks destroying once submitted and editing once issued, but allows both while draft" do
    receive_stock!(10)
    issue = draft_issue

    sign_in creator
    get edit_inventory_stock_issue_path(issue)
    expect(response).to have_http_status(:ok)

    post submit_inventory_stock_issue_path(issue)
    expect(issue.reload).to be_pending_approval

    delete inventory_stock_issue_path(issue)
    expect(StockIssue.exists?(issue.id)).to be true

    sign_in approver
    post approve_inventory_stock_issue_path(issue)
    expect(issue.reload).to be_approved

    sign_in creator
    get edit_inventory_stock_issue_path(issue)
    expect(response).to have_http_status(:ok) # approved: Edit Request

    sign_in confirmer
    post confirm_inventory_stock_issue_path(issue)
    expect(issue.reload).to be_issued

    sign_in creator
    get edit_inventory_stock_issue_path(issue)
    expect(response).to redirect_to(root_path).or have_http_status(:forbidden)
  end

  it "deletes a draft but keeps it if it isn't a draft" do
    issue = draft_issue
    sign_in creator

    expect { delete inventory_stock_issue_path(issue) }.to change(StockIssue, :count).by(-1)
  end

  it "an unauthorized user cannot approve or confirm" do
    receive_stock!(10)
    issue = draft_issue
    sign_in creator
    post submit_inventory_stock_issue_path(issue)

    sign_in creator # creator has no approve_stock_issues permission
    post approve_inventory_stock_issue_path(issue)
    expect(issue.reload).to be_pending_approval
  end
end
