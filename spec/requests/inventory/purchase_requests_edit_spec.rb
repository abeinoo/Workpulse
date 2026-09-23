require "rails_helper"

RSpec.describe "Purchase Requests — edit", type: :request do
  let(:business)   { create(:business) }
  let(:owner)      { create(:user, :super_admin, business: business) }
  let(:supplier)   { business.suppliers.create!(name: "Acme") }
  let(:supplier_2) { business.suppliers.create!(name: "Beta") }
  let!(:product_a) { business.products.create!(name: "Product A", sku: "A-1", average_cost_price: 100) }

  def draft_request
    pr = business.purchase_requests.build(supplier: supplier, source: "low_stock_alert", created_by: owner)
    pr.items.build(product: product_a, quantity: 10, unit_price: 100)
    pr.save!
    pr
  end

  describe "GET /inventory/purchase_requests/:id/edit" do
    it "renders the edit form for a draft request" do
      pr = draft_request
      sign_in owner

      get edit_inventory_purchase_request_path(pr)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(pr.request_number)
      expect(response.body).to include("Product A")
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
          supplier_id: supplier_2.id, notes: "Please expedite",
          items_attributes: { "0" => { id: pr.items.first.id, product_id: product_a.id, quantity: 12, unit_price: 100 } }
        }
      }

      expect(response).to redirect_to(inventory_purchase_request_path(pr))
      follow_redirect!
      expect(response.body).to include(I18n.t("inventory.purchase_requests.updated"))
      expect(pr.reload.supplier).to eq(supplier_2)
      expect(pr.items.first.quantity).to eq(12)
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
end
