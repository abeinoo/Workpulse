require "rails_helper"

RSpec.describe "Purchase Requests — edit", type: :request do
  let(:business)   { create(:business) }
  let(:owner)      { create(:user, :super_admin, business: business) }
  let(:supplier)   { business.suppliers.create!(name: "Acme") }
  let(:supplier_2) { business.suppliers.create!(name: "Beta") }
  let!(:product_a) { business.products.create!(name: "Product A", sku: "A-1", average_cost_price: 100) }
  let!(:warehouse)  { business.warehouses.create!(name: "Main WH") }
  let!(:warehouse_2) { business.warehouses.create!(name: "Second WH") }
  let!(:responsible) { purchaser_with_custody(business, first_name: "Rami") }

  def draft_request
    pr = business.purchase_requests.build(warehouse: warehouse, source: "low_stock_alert", created_by: owner,
                                          responsible_employee: responsible)
    pr.items.build(product: product_a, quantity: 10, unit_price: 100, supplier: supplier)
    pr.save!
    pr
  end

  # Created before the warehouse/supplier refactor: request-level supplier,
  # no request-level warehouse.
  def legacy_draft_request
    pr = business.purchase_requests.build(supplier: supplier, source: "low_stock_alert", created_by: owner)
    pr.items.build(product: product_a, quantity: 10, unit_price: 100, supplier: supplier)
    pr.save!
    pr
  end

  def line_params(pr, **overrides)
    item = pr.items.first
    { "0" => { id: item.id, product_id: product_a.id, quantity: item.quantity, unit_price: item.unit_price,
               supplier_id: item.supplier_id }.merge(overrides) }
  end

  describe "GET /inventory/purchase_requests/:id/edit" do
    it "renders the edit form for a draft request" do
      pr = draft_request
      sign_in owner

      get edit_inventory_purchase_request_path(pr)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(pr.request_number)
      expect(response.body).to include("Product A")
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("select[name='purchase_request[warehouse_id]'] option[selected]")["value"]).to eq(warehouse.id.to_s)
      expect(doc.at_css("table.line-items-table select[name*='[supplier_id]'] option[selected]")["value"]).to eq(supplier.id.to_s)
      expect(doc.at_css('select[name="purchase_request[supplier_id]"]')).to be_nil
    end

    it "shows a legacy draft's request-level supplier and asks for its warehouse" do
      pr = legacy_draft_request
      sign_in owner

      get edit_inventory_purchase_request_path(pr)

      expect(response.body).to include(I18n.t("inventory.purchase_requests.form.legacy_supplier_hint"))
      expect(Nokogiri::HTML(response.body).at_css("select[name='purchase_request[warehouse_id]'] option[selected]")).to be_nil
    end

    it "refuses (backend-enforced) for a non-draft request, even if a user guesses the URL" do
      pr = draft_request
      pr.update_column(:status, "approved")
      sign_in owner

      get edit_inventory_purchase_request_path(pr)
      expect(response).to redirect_to(root_path)
    end

    # 13. Unauthorized user cannot edit
    it "denies a user without create_purchase_requests (or manage_inventory)" do
      pr = draft_request
      role = business.permission_roles.create!(name: "Viewer", permissions: %w[view_inventory])
      viewer = create(:user, business: business)
      viewer.update_column(:permission_role_id, role.id)
      sign_in viewer

      get edit_inventory_purchase_request_path(pr)
      expect(response).to redirect_to(root_path)
    end
  end

  describe "PATCH /inventory/purchase_requests/:id" do
    it "updates a draft request and redirects to the show page with a success notice" do
      pr = draft_request
      sign_in owner

      patch inventory_purchase_request_path(pr), params: {
        purchase_request: {
          warehouse_id: warehouse_2.id, notes: "Please expedite",
          items_attributes: line_params(pr, quantity: 12, supplier_id: supplier_2.id)
        }
      }

      expect(response).to redirect_to(inventory_purchase_request_path(pr))
      follow_redirect!
      expect(response.body).to include(I18n.t("inventory.purchase_requests.updated"))
      pr.reload
      expect(pr.warehouse).to eq(warehouse_2)
      expect(pr.items.first.supplier).to eq(supplier_2)
      expect(pr.items.first.quantity).to eq(12)
      expect(pr.supplier_id).to be_nil
    end

    it "gives a legacy draft its warehouse on save (responsible employee optional), keeping its request-level supplier" do
      pr = legacy_draft_request
      sign_in owner

      patch inventory_purchase_request_path(pr), params: { purchase_request: { notes: "x" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(I18n.t("inventory.purchase_requests.errors.missing_warehouse"))

      patch inventory_purchase_request_path(pr), params: { purchase_request: { warehouse_id: warehouse.id, notes: "x" } }
      expect(response).to redirect_to(inventory_purchase_request_path(pr))
      expect(pr.reload.responsible_employee_id).to be_nil

      patch inventory_purchase_request_path(pr), params: {
        purchase_request: { warehouse_id: warehouse.id, responsible_employee_id: responsible.id, notes: "x" }
      }
      expect(response).to redirect_to(inventory_purchase_request_path(pr))
      expect(pr.reload.warehouse).to eq(warehouse)
      expect(pr.responsible_employee).to eq(responsible)
      expect(pr.supplier).to eq(supplier)
    end

    it "does NOT show or use the 'submit for approval' flow — the request stays draft after edit" do
      pr = draft_request
      sign_in owner

      patch inventory_purchase_request_path(pr), params: {
        purchase_request: { notes: "edited" }
      }

      expect(pr.reload).to be_draft
    end

    it "refuses to update a non-draft request server-side, regardless of the UI" do
      pr = draft_request
      pr.update_column(:status, "pending_approval")
      sign_in owner

      patch inventory_purchase_request_path(pr), params: { purchase_request: { notes: "hacked" } }

      expect(response).to redirect_to(root_path)
      expect(pr.reload.notes).not_to eq("hacked")
    end

    it "denies an unauthorized user" do
      pr = draft_request
      role = business.permission_roles.create!(name: "Viewer", permissions: %w[view_inventory])
      viewer = create(:user, business: business)
      viewer.update_column(:permission_role_id, role.id)
      sign_in viewer

      patch inventory_purchase_request_path(pr), params: { purchase_request: { notes: "hacked" } }
      expect(response).to redirect_to(root_path)
      expect(pr.reload.notes).not_to eq("hacked")
    end

    it "re-renders the edit form with an error on invalid input, without losing draft status" do
      pr = draft_request
      sign_in owner

      patch inventory_purchase_request_path(pr), params: {
        purchase_request: {
          items_attributes: { "0" => { id: pr.items.first.id, product_id: product_a.id, quantity: -1, unit_price: 100 } }
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(pr.reload).to be_draft
      expect(pr.items.first.quantity).to eq(10)
    end

    it "does not change inventory or create a goods receipt" do
      pr = draft_request
      sign_in owner

      expect {
        patch inventory_purchase_request_path(pr), params: { purchase_request: { notes: "edited" } }
      }.not_to change(InventoryMovement, :count)

      expect(GoodsReceipt.where(purchase_request: pr).count).to eq(0)
    end
  end

  describe "UI: تعديل visibility" do
    it "shows the edit action only for a draft request on the show and index pages" do
      draft = draft_request
      approved = draft_request
      approved.update_columns(status: "approved")

      sign_in owner

      get inventory_purchase_request_path(draft)
      expect(response.body).to include(edit_inventory_purchase_request_path(draft))

      get inventory_purchase_request_path(approved)
      expect(response.body).not_to include(edit_inventory_purchase_request_path(approved))

      get inventory_purchase_requests_path
      expect(response.body).to include(edit_inventory_purchase_request_path(draft))
      expect(response.body).not_to include(edit_inventory_purchase_request_path(approved))
    end
  end

  describe "requests without a supplier" do
    def no_supplier_request
      pr = business.purchase_requests.build(source: "low_stock_alert", created_by: owner)
      pr.items.build(product: product_a, quantity: 10, unit_price: 100)
      pr.save!
      pr
    end

    it "AR: shows \"بدون مورد\" and the normal Submit for Approval action, with no supplier warning" do
      pr = no_supplier_request
      owner.update!(preferred_locale: "ar")
      sign_in owner

      get inventory_purchase_request_path(pr)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("بدون مورد")
      expect(response.body).to include(submit_inventory_purchase_request_path(pr))
      expect(response.body).not_to include("يجب تحديد المورد")
    end

    it "shows the Approve action to an approver while pending, without a supplier" do
      pr = no_supplier_request
      pr.update_columns(status: "pending_approval", submitted_by_id: create(:user, business: business).id)
      sign_in owner

      get inventory_purchase_request_path(pr)

      expect(response.body).to include(approve_inventory_purchase_request_path(pr))
    end

    it "lists it on the index with \"No supplier\" and the regular Edit next action" do
      no_supplier_request
      sign_in owner

      get inventory_purchase_requests_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("inventory.purchase_requests.no_supplier"))
      expect(response.body).to include(I18n.t("inventory.purchase_requests.next_actions.draft"))
    end

    it "filters the index to requests without a supplier" do
      without = no_supplier_request
      with    = draft_request
      sign_in owner

      get inventory_purchase_requests_path(supplier_id: PurchaseRequest::NO_SUPPLIER_FILTER)

      expect(response.body).to include(without.request_number)
      expect(response.body).not_to include(with.request_number)
    end

    it "assigns a supplier by editing the draft" do
      pr = no_supplier_request
      sign_in owner

      get edit_inventory_purchase_request_path(pr)
      expect(response).to have_http_status(:ok)

      patch inventory_purchase_request_path(pr), params: {
        purchase_request: { warehouse_id: warehouse.id, responsible_employee_id: responsible.id,
                            items_attributes: line_params(pr, supplier_id: supplier_2.id) }
      }
      expect(response).to redirect_to(inventory_purchase_request_path(pr))
      expect(pr.reload.items.sole.supplier).to eq(supplier_2)
      expect(pr.items.count).to eq(1)

      post submit_inventory_purchase_request_path(pr)
      expect(pr.reload).to be_pending_approval
    end

    it "submits for approval and approves while the supplier stays empty" do
      pr = no_supplier_request
      sign_in owner

      post submit_inventory_purchase_request_path(pr)
      expect(flash[:notice]).to eq(I18n.t("inventory.purchase_requests.submitted"))
      expect(pr.reload).to be_pending_approval

      # Self-approval is blocked; approve as a different user with the
      # approve permission (not a second :super_admin — that steals business.owner).
      role     = business.permission_roles.create!(name: "Approver", permissions: %w[view_inventory approve_purchase_requests])
      approver = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
      sign_in approver
      post approve_inventory_purchase_request_path(pr)
      expect(flash[:notice]).to eq(I18n.t("inventory.purchase_requests.approved"))
      expect(pr.reload).to be_approved
      expect(pr.supplier_id).to be_nil
    end

    it "lets an existing line supplier be cleared on a draft" do
      pr = draft_request
      sign_in owner

      patch inventory_purchase_request_path(pr), params: { purchase_request: { items_attributes: line_params(pr, supplier_id: "") } }

      expect(pr.reload.items.sole.supplier_id).to be_nil
    end

    it "keeps showing the supplier for a legacy request that has one" do
      pr = legacy_draft_request
      sign_in owner

      get inventory_purchase_request_path(pr)

      expect(response.body).to include("Acme")
    end
  end
end
