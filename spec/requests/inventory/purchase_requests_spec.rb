require "rails_helper"

RSpec.describe "Purchase Requests", type: :request do
  let(:business)   { create(:business) }
  let(:owner)      { create(:user, :super_admin, business: business) }
  let(:supplier_1) { business.suppliers.create!(name: "Supplier 1") }
  let(:supplier_2) { business.suppliers.create!(name: "Supplier 2") }
  let!(:warehouse_a) { business.warehouses.create!(name: "WH A") }
  let!(:warehouse_b) { business.warehouses.create!(name: "WH B") }
  let!(:responsible) { purchaser_with_custody(business, first_name: "Rami") }

  let!(:product_a) { business.products.create!(name: "Product A", sku: "A-1", average_cost_price: 100) }
  let!(:product_b) { business.products.create!(name: "Product B", sku: "B-1", average_cost_price: 200) }
  let!(:product_c) { business.products.create!(name: "Product C", sku: "C-1", average_cost_price: 150) }

  # One Low Stock review-modal line (items[]).
  def item_params(product, supplier, qty:, price:, warehouse: warehouse_a)
    { product_id: product.id, quantity: qty, unit_price: price, supplier_id: supplier&.id, warehouse_id: warehouse&.id }
  end

  describe "POST /inventory/purchase_requests (Low Stock review modal)" do
    it "creates one Purchase Request per warehouse, each with several suppliers, and redirects with a success notice" do
      sign_in owner

      post inventory_purchase_requests_path, params: {
        idempotency_key: SecureRandom.uuid, responsible_employee_id: responsible.id,
        items: [
          item_params(product_a, supplier_1, qty: 10, price: 100, warehouse: warehouse_a),
          item_params(product_b, supplier_2, qty: 5,  price: 200, warehouse: warehouse_a),
          item_params(product_c, supplier_2, qty: 8,  price: 150, warehouse: warehouse_b)
        ]
      }

      expect(response).to redirect_to(%r{/inventory/purchase_requests})
      follow_redirect!
      expect(response.body).to include(I18n.t("inventory.purchase_requests.just_created_title"))
      expect(PurchaseRequest.count).to eq(2)
      expect(PurchaseRequest.pluck(:status).uniq).to eq([ "draft" ])
      in_a = PurchaseRequest.find_by!(warehouse: warehouse_a)
      expect(in_a.items.map { |i| [ i.product, i.supplier ] }).to contain_exactly([ product_a, supplier_1 ], [ product_b, supplier_2 ])
      expect(PurchaseRequest.find_by!(warehouse: warehouse_b).items.map(&:product)).to contain_exactly(product_c)
      expect(PurchaseRequest.pluck(:supplier_id).uniq).to eq([ nil ])
    end

    it "keeps lines without a supplier in their warehouse's request" do
      sign_in owner

      expect {
        post inventory_purchase_requests_path, params: {
          idempotency_key: SecureRandom.uuid, responsible_employee_id: responsible.id,
          items: [
            item_params(product_a, supplier_1, qty: 10, price: 100),
            item_params(product_b, nil,        qty: 5,  price: 200)
          ]
        }
      }.to change(PurchaseRequest, :count).by(1)

      expect(PurchaseRequest.last.items.find_by!(product: product_b).supplier).to be_nil
    end

    it "never creates a request for a line without a warehouse (total-stock alert left unassigned)" do
      sign_in owner

      expect {
        post inventory_purchase_requests_path, params: {
          idempotency_key: SecureRandom.uuid, responsible_employee_id: responsible.id,
          items: [
            item_params(product_a, supplier_1, qty: 1, price: 100),
            item_params(product_b, supplier_1, qty: 1, price: 100, warehouse: nil)
          ]
        }
      }.not_to change(PurchaseRequest, :count)

      expect(response).to redirect_to(inventory_root_path)
      expect(flash[:alert]).to eq(I18n.t("inventory.purchase_requests.errors.missing_warehouse"))
    end

    it "does not create duplicate requests when the same idempotency key is submitted twice" do
      sign_in owner
      key = SecureRandom.uuid
      params = {
        idempotency_key: key, responsible_employee_id: responsible.id,
        items: [
          item_params(product_a, supplier_1, qty: 10, price: 100, warehouse: warehouse_a),
          item_params(product_b, supplier_1, qty: 10, price: 100, warehouse: warehouse_b)
        ]
      }

      post inventory_purchase_requests_path, params: params
      expect {
        post inventory_purchase_requests_path, params: params
      }.not_to change(PurchaseRequest, :count)
      expect(PurchaseRequest.count).to eq(2)
    end

    it "denies a user without create_purchase_requests (or manage_inventory) permission" do
      role = business.permission_roles.create!(name: "Viewer", permissions: %w[view_inventory])
      viewer = create(:user, business: business)
      viewer.update_column(:permission_role_id, role.id)
      sign_in viewer

      post inventory_purchase_requests_path, params: {
        idempotency_key: SecureRandom.uuid, responsible_employee_id: responsible.id,
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
        idempotency_key: SecureRandom.uuid, responsible_employee_id: responsible.id,
        items: [ item_params(product_a, supplier_1, qty: 10, price: 100) ]
      }

      expect(PurchaseRequest.count).to eq(1)
    end

    it "does not change inventory when creating a purchase request" do
      sign_in owner

      expect {
        post inventory_purchase_requests_path, params: {
          idempotency_key: SecureRandom.uuid, responsible_employee_id: responsible.id,
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
        idempotency_key: SecureRandom.uuid, responsible_employee_id: responsible.id,
        items: [ item_params(product_a, supplier_1, qty: 10, price: 100) ]
      }
      pr = PurchaseRequest.last

      get inventory_purchase_request_path(pr)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(pr.request_number)
      expect(response.body).to include("Supplier 1")
      expect(response.body).to include("WH A")
      expect(response.body).to include(I18n.t("inventory.purchase_requests.source_low_stock_alert"))
    end

    it "shows each line's supplier and \"Multiple suppliers\" for the request" do
      sign_in owner
      post inventory_purchase_requests_path, params: {
        idempotency_key: SecureRandom.uuid, responsible_employee_id: responsible.id,
        items: [ item_params(product_a, supplier_1, qty: 1, price: 100), item_params(product_b, supplier_2, qty: 1, price: 100) ]
      }

      get inventory_purchase_request_path(PurchaseRequest.last)

      page = Nokogiri::HTML(response.body)
      rows = page.css("tbody tr").map(&:text)
      expect(rows.find { |r| r.include?("Product A") }).to include("Supplier 1")
      expect(rows.find { |r| r.include?("Product B") }).to include("Supplier 2")
      expect(response.body).to include(I18n.t("inventory.purchase_requests.multiple_suppliers"))
    end
  end

  describe "GET /inventory/purchase_requests (supplier filter / search)" do
    def new_request(lines, warehouse: warehouse_a)
      pr = business.purchase_requests.build(created_by: owner, warehouse: warehouse)
      lines.each { |product, supplier| pr.items.build(product: product, supplier: supplier, quantity: 1, unit_price: 10) }
      pr.save!
      pr
    end

    let!(:multi)   { new_request([ [ product_a, supplier_1 ], [ product_b, supplier_2 ] ]) }
    let!(:unknown) { new_request([ [ product_c, nil ] ]) }
    let!(:legacy) do
      pr = business.purchase_requests.build(created_by: owner, supplier: supplier_2)
      pr.items.build(product: product_a, quantity: 1, unit_price: 10)
      pr.save!
      pr
    end

    before { sign_in owner }

    it "matches a supplier on any line, and a legacy request-level supplier" do
      get inventory_purchase_requests_path(supplier_id: supplier_2.id)
      expect(response.body).to include(multi.request_number, legacy.request_number)
      expect(response.body).not_to include(unknown.request_number)

      get inventory_purchase_requests_path(supplier_id: supplier_1.id)
      expect(response.body).to include(multi.request_number)
      expect(response.body).not_to include(legacy.request_number, unknown.request_number)
    end

    it "keeps the \"No supplier\" filter for requests with no supplier anywhere" do
      get inventory_purchase_requests_path(supplier_id: PurchaseRequest::NO_SUPPLIER_FILTER)

      expect(response.body).to include(unknown.request_number)
      expect(response.body).not_to include(multi.request_number, legacy.request_number)
    end

    it "searches line supplier names" do
      get inventory_purchase_requests_path(q: "supplier 1")

      expect(response.body).to include(multi.request_number)
      expect(response.body).not_to include(unknown.request_number, legacy.request_number)
    end

    it "labels a several-supplier request \"Multiple suppliers\"" do
      get inventory_purchase_requests_path

      expect(response.body).to include(I18n.t("inventory.purchase_requests.multiple_suppliers"))
    end
  end
end
