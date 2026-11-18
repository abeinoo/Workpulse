require "rails_helper"

# Warehouse Architecture PR 5 (D5): purchase requests are scoped by warehouse
# access — viewing (index, show, nested pages) and approving (single and bulk).
RSpec.describe "Purchase Requests — warehouse scoping", type: :request do
  let(:business)  { create(:business) }
  let(:other)     { create(:business) }
  let(:requester) { create(:user, business: business) }
  let!(:assigned_wh)   { business.warehouses.create!(name: "Assigned") }
  let!(:unassigned_wh) { business.warehouses.create!(name: "Unassigned") }
  let(:product) { business.products.create!(name: "Widget", sku: "W-1", average_cost_price: 1) }

  def approver(*extra)
    user_with_stock_permissions(business, :view_inventory, :approve_purchase_requests, *extra)
  end

  def restricted_to(*warehouses)
    approver.tap { |u| warehouses.each { |w| WarehouseAssignment.create!(user: u, warehouse: w) } }
  end

  def pending_request(warehouse: nil, line_warehouses: [ nil ], business: self.business, product: self.product)
    pr = business.purchase_requests.build(warehouse: warehouse, created_by: requester)
    line_warehouses.each { |w| pr.items.build(product: product, quantity: 1, unit_price: 10, source_warehouse: w) }
    pr.save!
    pr.update_columns(status: "pending_approval", submitted_by_id: requester.id)
    pr
  end

  let!(:pr_assigned)   { pending_request(warehouse: assigned_wh) }
  let!(:pr_unassigned) { pending_request(warehouse: unassigned_wh) }
  let!(:legacy_inside) { pending_request(line_warehouses: [ assigned_wh, assigned_wh ]) }
  let!(:legacy_mixed)  { pending_request(line_warehouses: [ assigned_wh, unassigned_wh ]) }
  let!(:legacy_none)   { pending_request(line_warehouses: [ nil ]) }

  def scope_for(user) = PurchaseRequestPolicy::Scope.new(user, PurchaseRequest).resolve.order(:id).to_a

  describe PurchaseRequestPolicy::Scope do
    it "shows a restricted user only the requests of their warehouses (legacy: every line inside)" do
      expect(scope_for(restricted_to(assigned_wh))).to eq([ pr_assigned, legacy_inside ])
    end

    it "keeps the whole business for the owner" do
      expect(scope_for(create(:user, :owner, business: business)).size).to eq(5)
    end

    it "keeps the whole business for an access_all_warehouses holder (central purchasing)" do
      expect(scope_for(approver(:access_all_warehouses)).size).to eq(5)
    end

    it "shows nothing — never the whole business — for an empty access set" do
      user = approver
      allow(user).to receive(:inventory_warehouse_ids).and_return([])
      expect(scope_for(user)).to be_empty
    end

    it "never shows another business's requests" do
      foreign_product = other.products.create!(name: "Foreign", sku: "F-1", average_cost_price: 1)
      foreign_pr = pending_request(business: other, warehouse: other.warehouses.create!(name: "F"), product: foreign_product)

      expect(scope_for(create(:user, :owner, business: business))).not_to include(foreign_pr)
      expect(scope_for(approver(:access_all_warehouses))).not_to include(foreign_pr)
    end
  end

  describe "viewing" do
    it "lists only the reachable requests on the index" do
      sign_in restricted_to(assigned_wh)
      get inventory_purchase_requests_path

      expect(response.body).to include(pr_assigned.request_number, legacy_inside.request_number)
      expect(response.body).not_to include(pr_unassigned.request_number)
      expect(response.body).not_to include(legacy_mixed.request_number)
      expect(response.body).not_to include(legacy_none.request_number)
    end

    it "shows a reachable request and 404s an unreachable one" do
      sign_in restricted_to(assigned_wh)

      get inventory_purchase_request_path(pr_assigned)
      expect(response).to have_http_status(:ok)

      get inventory_purchase_request_path(pr_unassigned)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "approval" do
    it "approves a request of an assigned warehouse" do
      sign_in restricted_to(assigned_wh)
      post approve_inventory_purchase_request_path(pr_assigned)

      expect(pr_assigned.reload).to be_approved
    end

    it "cannot approve a request of an unassigned warehouse (not found), which stays pending" do
      sign_in restricted_to(assigned_wh)
      post approve_inventory_purchase_request_path(pr_unassigned)

      expect(response).to have_http_status(:not_found)
      expect(pr_unassigned.reload).to be_pending_approval
    end

    it "refuses approval in the policy as well, for an unreachable request loaded elsewhere" do
      expect(PurchaseRequestPolicy.new(restricted_to(assigned_wh), pr_unassigned).approve?).to be(false)
      expect(PurchaseRequestPolicy.new(restricted_to(assigned_wh), pr_assigned).approve?).to be(true)
    end

    it "refuses the single-approval service for an unreachable request" do
      service = Inventory::PurchaseRequestApproval.new(purchase_request_id: pr_unassigned.id, actor: restricted_to(assigned_wh))

      expect { service.approve! }.to raise_error(ActiveRecord::RecordNotFound)
      expect(pr_unassigned.reload).to be_pending_approval
    end

    it "refuses a whole bulk approval that includes an unreachable request — nothing is approved" do
      sign_in restricted_to(assigned_wh)
      post bulk_approve_inventory_purchase_requests_path,
           params: { purchase_request_ids: [ pr_assigned.id, pr_unassigned.id ] },
           headers: { "HTTP_REFERER" => inventory_purchase_requests_url }

      expect(flash[:alert]).to eq(I18n.t("inventory.purchase_requests.errors.bulk_unavailable"))
      expect([ pr_assigned.reload, pr_unassigned.reload ]).to all(be_pending_approval)
    end

    it "lets central purchasing (access_all_warehouses) approve across the business" do
      sign_in approver(:access_all_warehouses)
      post bulk_approve_inventory_purchase_requests_path,
           params: { purchase_request_ids: [ pr_assigned.id, pr_unassigned.id ] },
           headers: { "HTTP_REFERER" => inventory_purchase_requests_url }

      expect([ pr_assigned.reload, pr_unassigned.reload ]).to all(be_approved)
    end
  end

  describe "creation and update (already warehouse-checked, unchanged)" do
    it "refuses creating a request for an unassigned warehouse" do
      creator = user_with_stock_permissions(business, :view_inventory, :create_purchase_requests)
      WarehouseAssignment.create!(user: creator, warehouse: assigned_wh)

      result = Inventory::PurchaseRequestCreator.new(
        business, actor: creator, items: [ { product_id: product.id, quantity: 1, warehouse_id: unassigned_wh.id } ]
      ).call

      expect(result).not_to be_ok
    end
  end
end
