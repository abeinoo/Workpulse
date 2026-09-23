require "rails_helper"

RSpec.describe "Purchase Requests — close remaining", type: :request do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let(:supplier)  { business.suppliers.create!(name: "Acme") }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let!(:product)  { business.products.create!(name: "Widget", sku: "W-1", average_cost_price: 100) }

  def approved_request(quantity: 10)
    pr = business.purchase_requests.build(supplier: supplier, source: "low_stock_alert", created_by: owner)
    pr.items.build(product: product, quantity: quantity, unit_price: 100)
    pr.save!
    pr.update_column(:status, "approved")
    pr.reload
  end

  def confirm_receipt!(pr, quantity:)
    receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current,
                                            purchase_request: pr)
    receipt.items.build(product: product, quantity: quantity, unit_cost: 100, purchase_request_item: pr.items.sole)
    receipt.save!
    receipt.update_column(:approval_status, "approved")
    result = Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: receipt.id, actor: owner).call
    raise "confirmation failed: #{result.error}" unless result.ok?

    receipt
  end

  describe "POST /inventory/purchase_requests/:id/close_remaining" do
    it "closes the remaining quantity, redirects with a success notice, and shows the new status" do
      pr = approved_request(quantity: 10)
      confirm_receipt!(pr, quantity: 6)
      sign_in owner

      post close_remaining_inventory_purchase_request_path(pr), params: { close_remaining_reason: "No longer needed" }

      expect(response).to redirect_to(inventory_purchase_request_path(pr))
      follow_redirect!
      expect(response.body).to include(I18n.t("inventory.purchase_requests.remaining_closed"))
      expect(response.body).to include(I18n.t("inventory.purchase_requests.statuses.partially_closed"))
      expect(pr.reload).to be_partially_closed
    end

    it "requires a reason" do
      pr = approved_request(quantity: 10)
      confirm_receipt!(pr, quantity: 6)
      sign_in owner

      post close_remaining_inventory_purchase_request_path(pr), params: { close_remaining_reason: "" }

      expect(pr.reload).to be_partially_received
    end

    it "refuses for a fully received request" do
      pr = approved_request(quantity: 10)
      confirm_receipt!(pr, quantity: 10)
      sign_in owner

      post close_remaining_inventory_purchase_request_path(pr), params: { close_remaining_reason: "x" }

      expect(pr.reload).to be_fully_received
    end

    it "refuses for an approved request with nothing received" do
      pr = approved_request(quantity: 10)
      sign_in owner

      post close_remaining_inventory_purchase_request_path(pr), params: { close_remaining_reason: "x" }

      expect(pr.reload).to be_approved
    end

    it "denies a user without approve_purchase_requests (or manage_inventory)" do
      pr = approved_request(quantity: 10)
      confirm_receipt!(pr, quantity: 6)
      role = business.permission_roles.create!(name: "Creator only", permissions: %w[view_inventory create_purchase_requests])
      user = create(:user, business: business)
      user.update_column(:permission_role_id, role.id)
      sign_in user

      post close_remaining_inventory_purchase_request_path(pr), params: { close_remaining_reason: "x" }

      expect(response).to redirect_to(root_path)
      expect(pr.reload).to be_partially_received
    end

    it "does not change inventory or create a goods receipt" do
      pr = approved_request(quantity: 10)
      confirm_receipt!(pr, quantity: 6)
      sign_in owner

      expect {
        post close_remaining_inventory_purchase_request_path(pr), params: { close_remaining_reason: "x" }
      }.not_to change(InventoryMovement, :count)

      expect(product.reload.current_stock).to eq(6)
      expect(pr.goods_receipts.count).to eq(1)
    end
  end

  describe "Goods Receipt protection after closing" do
    it "blocks creating a new Goods Receipt for a partially closed request, server-side" do
      pr = approved_request(quantity: 10)
      confirm_receipt!(pr, quantity: 6)
      sign_in owner
      post close_remaining_inventory_purchase_request_path(pr), params: { close_remaining_reason: "x" }
      expect(pr.reload).to be_partially_closed

      get new_inventory_goods_receipt_path(purchase_request_id: pr.id)
      expect(response).to redirect_to(root_path)

      post inventory_goods_receipts_path, params: {
        goods_receipt: {
          purchase_request_id: pr.id, warehouse_id: warehouse.id, supplier_id: supplier.id,
          received_on: Date.current.to_s, funding_source_kind: "supplier_credit",
          items_attributes: { "0" => { product_id: product.id, quantity: 4, unit_cost: 100 } }
        }
      }
      expect(GoodsReceipt.where(purchase_request: pr).count).to eq(1) # only the original one
    end

    it "hides the 'Create Goods Receipt' action on show and index for a partially closed request" do
      pr = approved_request(quantity: 10)
      confirm_receipt!(pr, quantity: 6)
      sign_in owner
      post close_remaining_inventory_purchase_request_path(pr), params: { close_remaining_reason: "x" }

      get inventory_purchase_request_path(pr)
      expect(response.body).not_to include(new_inventory_goods_receipt_path(purchase_request_id: pr.id))

      get inventory_purchase_requests_path
      expect(response.body).not_to include(new_inventory_goods_receipt_path(purchase_request_id: pr.id))
    end
  end

  describe "receiving summary on the show page" do
    it "shows requested/received/closed after closing the remainder" do
      pr = approved_request(quantity: 10)
      confirm_receipt!(pr, quantity: 6)
      sign_in owner
      post close_remaining_inventory_purchase_request_path(pr), params: { close_remaining_reason: "x" }

      get inventory_purchase_request_path(pr)
      expect(response.body).to include(I18n.t("inventory.purchase_requests.total_closed"))
      # 6 received, 4 closed
      expect(response.body).to include("6")
      expect(response.body).to include("4")
    end
  end
end
