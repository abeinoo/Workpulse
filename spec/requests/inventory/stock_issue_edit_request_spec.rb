require "rails_helper"

RSpec.describe "Inventory::StockIssues Edit Request (pending approval)", type: :request do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:branch)    { business.branches.create!(name: "Nasr City", active: true) }
  let(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10) }
  let(:product2)  { business.products.create!(name: "Towel", sku: "TW-1", initial_cost_price: 5, average_cost_price: 5) }

  let(:creator_role)  { create(:permission_role, business: business, permissions: %w[view_inventory manage_stock_issues]) }
  let(:creator)       { create(:user, business: business, permission_role: creator_role) }
  let(:approver_role) { create(:permission_role, business: business, permissions: %w[view_inventory approve_stock_issues]) }
  let(:approver)      { create(:user, business: business, permission_role: approver_role) }
  let(:viewer_role)   { create(:permission_role, business: business, permissions: %w[view_inventory]) }
  let(:viewer)        { create(:user, business: business, permission_role: viewer_role) }

  let(:issue) do
    i = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current, created_by: creator)
    i.items.build(product: product, quantity: 2)
    i.save!
    Inventory::StockIssueSubmission.new(stock_issue_id: i.id, actor: creator).call
    i.reload
  end

  def update_params(quantity:, lock_token: issue.lock_token)
    { lock_token: lock_token,
      stock_issue: { warehouse_id: warehouse.id, branch_id: branch.id, issued_on: Date.current,
                     items_attributes: { "0" => { id: issue.items.first.id, product_id: product.id, quantity: quantity },
                                         "1" => { product_id: product2.id, quantity: 1 } } } }
  end

  it "shows an Edit Request action on the pending issue and a withdrawal warning on the form" do
    sign_in creator
    get inventory_stock_issue_path(issue)
    expect(response.body).to include(I18n.t("inventory.stock_issues.edit_request"))

    get edit_inventory_stock_issue_path(issue)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("edit-request-warning")
    expect(response.body).to include(CGI.escapeHTML(I18n.t("inventory.stock_issues.save_and_return_to_draft")))
  end

  it "saves the edit, returns the issue to draft, and asks for resubmission" do
    sign_in creator
    patch inventory_stock_issue_path(issue), params: update_params(quantity: 5)

    expect(response).to redirect_to(inventory_stock_issue_path(issue))
    expect(flash[:notice]).to eq(I18n.t("inventory.stock_issues.reopened_for_editing"))
    expect(issue.reload).to be_draft
    expect(issue.items.count).to eq(2)

    follow_redirect!
    expect(response.body).to include("resubmission-required-notice")
    expect(response.body).to include(I18n.t("inventory.stock_issues.resubmit_for_approval"))
    expect(response.body).to include(I18n.t("inventory.stock_issues.timeline.reopened"))

    post submit_inventory_stock_issue_path(issue)
    expect(issue.reload).to be_pending_approval
  end

  it "re-renders with an alert on a stale edit and keeps the newer lines" do
    stale = issue.lock_token
    sign_in creator
    travel 1.second do
      patch inventory_stock_issue_path(issue), params: update_params(quantity: 3, lock_token: stale)
    end
    patch inventory_stock_issue_path(issue), params: update_params(quantity: 9, lock_token: stale)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include(CGI.escapeHTML(I18n.t("inventory.stock_issues.errors.stale_edit")))
    expect(issue.reload.items.find_by(product: product).quantity.to_i).to eq(3)
  end

  describe "authorization" do
    def role_user(permissions)
      create(:user, business: business, permission_role: create(:permission_role, business: business, permissions: permissions))
    end

    def expect_untouched
      issue.reload
      expect(issue).to be_pending_approval
      expect(issue.items.map { |i| [ i.product_id, i.quantity.to_i ] }).to eq([ [ product.id, 2 ] ])
      expect(AuditLog.for_auditable(issue).where(action: %w[reopen_for_editing update])).to be_empty
    end

    it "allows manage_stock_issues and manage_inventory holders" do
      [ %w[view_inventory manage_stock_issues], %w[view_inventory manage_inventory] ].each do |perms|
        i = issue
        Inventory::StockIssueSubmission.new(stock_issue_id: i.id, actor: creator).call if i.reload.draft?
        sign_in role_user(perms)
        patch inventory_stock_issue_path(i), params: update_params(quantity: 5, lock_token: i.reload.lock_token)
        expect(i.reload).to be_draft, perms.inspect
      end
    end

    it "refuses viewers, approvers, confirmers, and users with no inventory permission" do
      [ viewer, approver, role_user(%w[view_inventory confirm_stock_issues]), role_user(%w[view_inventory approve_stock_issues confirm_stock_issues]), role_user([]) ].each do |user|
        sign_in user
        get edit_inventory_stock_issue_path(issue)
        expect(response).not_to have_http_status(:ok)
        patch inventory_stock_issue_path(issue), params: update_params(quantity: 5)
        expect_untouched
      end
    end

    it "hides the Edit Request action from users who can't edit" do
      sign_in approver
      get inventory_stock_issue_path(issue)
      expect(response.body).not_to include("edit-stock-issue")
    end

    it "refuses a user from another business (not found)" do
      other_business = create(:business)
      outsider = create(:user, business: other_business,
                               permission_role: create(:permission_role, business: other_business,
                                                                         permissions: %w[view_inventory manage_inventory]))
      sign_in outsider
      begin
        patch inventory_stock_issue_path(issue), params: update_params(quantity: 5)
        expect(response).to have_http_status(:not_found)
      rescue ActiveRecord::RecordNotFound
        # raised through in the test env — equally a refusal
      end
      expect_untouched
    end

    it "refuses an editor restricted to a different warehouse (not found)" do
      other_wh = business.warehouses.create!(name: "Other")
      scoped = role_user(%w[view_inventory manage_stock_issues])
      WarehouseAssignment.create!(user: scoped, warehouse: other_wh)
      sign_in scoped
      begin
        patch inventory_stock_issue_path(issue), params: update_params(quantity: 5)
        expect(response).to have_http_status(:not_found)
      rescue ActiveRecord::RecordNotFound
        # raised through in the test env — equally a refusal
      end
      expect_untouched
    end

    it "refuses moving the issue into a warehouse the editor can't access" do
      other_wh = business.warehouses.create!(name: "Other")
      scoped = role_user(%w[view_inventory manage_stock_issues])
      WarehouseAssignment.create!(user: scoped, warehouse: warehouse)
      sign_in scoped
      params = update_params(quantity: 5)
      params[:stock_issue][:warehouse_id] = other_wh.id
      patch inventory_stock_issue_path(issue), params: params
      expect(response).to redirect_to(root_path).or have_http_status(:forbidden)
      expect_untouched
      expect(issue.warehouse_id).to eq(warehouse.id)
    end

    it "refuses editing once approved, even with edit permission" do
      business.goods_receipts.build(warehouse: warehouse, received_on: Date.current).tap do |r|
        r.items.build(product: product, quantity: 10, unit_cost: 10)
        Inventory::GoodsReceiptPoster.new(r).call
      end
      Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: approver).approve!
      sign_in creator
      patch inventory_stock_issue_path(issue), params: update_params(quantity: 5)
      expect(issue.reload).to be_approved
      expect(issue.items.count).to eq(1)
    end
  end

  describe "inventory integrity end to end" do
    it "edit -> resubmit -> approve creates no movements; confirm deducts exactly once" do
      business.goods_receipts.build(warehouse: warehouse, received_on: Date.current).tap do |r|
        r.items.build(product: product, quantity: 10, unit_cost: 10)
        r.items.build(product: product2, quantity: 10, unit_cost: 5)
        Inventory::GoodsReceiptPoster.new(r).call
      end
      confirmer = create(:user, business: business,
                                permission_role: create(:permission_role, business: business,
                                                                          permissions: %w[view_inventory confirm_stock_issues]))

      expect {
        sign_in creator
        patch inventory_stock_issue_path(issue), params: update_params(quantity: 4)
        post submit_inventory_stock_issue_path(issue)
        sign_in approver
        post approve_inventory_stock_issue_path(issue)
      }.not_to change(InventoryMovement, :count)
      expect(issue.reload).to be_approved
      expect([ product.reload.current_stock, product2.reload.current_stock ]).to eq([ 10, 10 ])

      sign_in confirmer
      expect {
        post confirm_inventory_stock_issue_path(issue)
        post confirm_inventory_stock_issue_path(issue) # double submit
      }.to change(InventoryMovement.where(source: issue), :count).by(2) # one per line, once
      expect(issue.reload).to be_issued
      expect([ product.reload.current_stock, product2.reload.current_stock ]).to eq([ 6, 9 ])
    end
  end
end
