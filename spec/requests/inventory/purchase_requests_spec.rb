require "rails_helper"

RSpec.describe "Purchase Requests", type: :request do
  let(:business)   { create(:business) }
  let(:owner)      { create(:user, :super_admin, business: business) }
  let(:supplier_1) { business.suppliers.create!(name: "Supplier 1") }
  let(:supplier_2) { business.suppliers.create!(name: "Supplier 2") }

  let!(:product_a) { business.products.create!(name: "Product A", sku: "A-1", average_cost_price: 100) }
  let!(:product_b) { business.products.create!(name: "Product B", sku: "B-1", average_cost_price: 200) }
  let!(:product_c) { business.products.create!(name: "Product C", sku: "C-1", average_cost_price: 150) }

  def item_params(product, supplier, qty:, price:)
    { product_id: product.id, quantity: qty, unit_price: price, supplier_id: supplier&.id }
  end

  describe "POST /inventory/purchase_requests" do
    it "creates one Purchase Request per supplier and redirects with a success notice" do
      sign_in owner

      post inventory_purchase_requests_path, params: {
        idempotency_key: SecureRandom.uuid,
        items: [
          item_params(product_a, supplier_1, qty: 10, price: 100),
          item_params(product_b, supplier_1, qty: 5,  price: 200),
          item_params(product_c, supplier_2, qty: 8,  price: 150)
        ]
      }

      expect(response).to redirect_to(%r{/inventory/purchase_requests})
      follow_redirect!
      expect(response.body).to include(I18n.t("inventory.purchase_requests.just_created_title"))
      expect(PurchaseRequest.count).to eq(2)
      expect(PurchaseRequest.pluck(:status).uniq).to eq([ "draft" ])
    end

    it "creates a separate no-supplier draft request for products left without a supplier" do
      sign_in owner

      expect {
        post inventory_purchase_requests_path, params: {
          idempotency_key: SecureRandom.uuid,
          items: [
            item_params(product_a, supplier_1, qty: 10, price: 100),
            item_params(product_b, nil,        qty: 5,  price: 200)
          ]
        }
      }.to change(PurchaseRequest, :count).by(2)

      no_supplier = PurchaseRequest.find_by!(supplier_id: nil)
      expect(no_supplier).to be_draft
      expect(no_supplier.items.map(&:product)).to contain_exactly(product_b)
      follow_redirect!
      expect(response.body).to include(I18n.t("inventory.purchase_requests.no_supplier"))
    end

    it "groups by the FINAL supplier chosen for each line (Supplier A, Supplier B, no supplier)" do
      sign_in owner
      product_d = business.products.create!(name: "Product D", sku: "D-1", average_cost_price: 50)
      product_e = business.products.create!(name: "Product E", sku: "E-1", average_cost_price: 60)

      # Product B's default would be Supplier 1 but it was moved to Supplier 2
      # in the review modal; the modal only ever posts the final choice.
      post inventory_purchase_requests_path, params: {
        idempotency_key: SecureRandom.uuid,
        items: [
          item_params(product_a, supplier_1, qty: 1, price: 100),
          item_params(product_b, supplier_2, qty: 1, price: 200),
          item_params(product_c, supplier_2, qty: 1, price: 150),
          item_params(product_d, supplier_1, qty: 1, price: 50),
          item_params(product_e, nil,        qty: 1, price: 60)
        ]
      }

      expect(PurchaseRequest.count).to eq(3)
      expect(PurchaseRequest.find_by!(supplier: supplier_1).items.map(&:product)).to contain_exactly(product_a, product_d)
      expect(PurchaseRequest.find_by!(supplier: supplier_2).items.map(&:product)).to contain_exactly(product_b, product_c)
      expect(PurchaseRequest.find_by!(supplier_id: nil).items.map(&:product)).to contain_exactly(product_e)
      expect(PurchaseRequestItem.count).to eq(5)
    end

    it "does not create duplicate requests when the same idempotency key is submitted twice" do
      sign_in owner
      key = SecureRandom.uuid
      params = {
        idempotency_key: key,
        items: [ item_params(product_a, supplier_1, qty: 10, price: 100) ]
      }

      post inventory_purchase_requests_path, params: params
      expect {
        post inventory_purchase_requests_path, params: params
      }.not_to change(PurchaseRequest, :count)
    end

    it "denies a user without create_purchase_requests (or manage_inventory) permission" do
      role = business.permission_roles.create!(name: "Viewer", permissions: %w[view_inventory])
      viewer = create(:user, business: business)
      viewer.update_column(:permission_role_id, role.id)
      sign_in viewer

      post inventory_purchase_requests_path, params: {
        idempotency_key: SecureRandom.uuid,
        items: [ item_params(product_a, supplier_1, qty: 10, price: 100) ]
      }

      expect(response).to redirect_to(root_path)
      expect(PurchaseRequest.count).to eq(0)
    end

    it "allows a user with the create_purchase_requests permission" do
      role = business.permission_roles.create!(name: "Buyer", permissions: %w[view_inventory create_purchase_requests])
      buyer = create(:user, business: business)
      buyer.update_column(:permission_role_id, role.id)
      sign_in buyer

      post inventory_purchase_requests_path, params: {
        idempotency_key: SecureRandom.uuid,
        items: [ item_params(product_a, supplier_1, qty: 10, price: 100) ]
      }

      expect(PurchaseRequest.count).to eq(1)
    end

    it "does not change inventory when creating a purchase request" do
      sign_in owner

      expect {
        post inventory_purchase_requests_path, params: {
          idempotency_key: SecureRandom.uuid,
          items: [ item_params(product_a, supplier_1, qty: 10, price: 100) ]
        }
      }.not_to change(InventoryMovement, :count)

      expect(product_a.reload.average_cost_price).to eq(100)
    end
  end

  describe "GET /inventory/purchase_requests/:id" do
    it "shows the request's items, supplier, and source" do
      sign_in owner
      post inventory_purchase_requests_path, params: {
        idempotency_key: SecureRandom.uuid,
        items: [ item_params(product_a, supplier_1, qty: 10, price: 100) ]
      }
      pr = PurchaseRequest.last

      get inventory_purchase_request_path(pr)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(pr.request_number)
      expect(response.body).to include("Supplier 1")
      expect(response.body).to include(I18n.t("inventory.purchase_requests.source_low_stock_alert"))
    end
  end
end
