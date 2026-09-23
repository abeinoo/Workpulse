require "rails_helper"

RSpec.describe "Purchase Request → Goods Receipt", type: :request do
  let(:business)   { create(:business) }
  let(:owner)      { create(:user, :super_admin, business: business) }
  let(:supplier)   { business.suppliers.create!(name: "Acme") }
  let(:warehouse)  { business.warehouses.create!(name: "Main") }
  let(:warehouse2) { business.warehouses.create!(name: "Branch") }
  let!(:product_a) { business.products.create!(name: "Product A", sku: "A-1", average_cost_price: 100) }
  let!(:product_b) { business.products.create!(name: "Product B", sku: "B-1", average_cost_price: 200) }

  def build_request(items_attrs)
    pr = business.purchase_requests.build(supplier: supplier, source: "low_stock_alert", created_by: owner)
    items_attrs.each { |attrs| pr.items.build(attrs) }
    pr.save!
    pr
  end

  def approve!(pr)
    pr.update_columns(status: "pending_approval", submitted_by_id: owner.id)
    Inventory::PurchaseRequestApproval.new(purchase_request_id: pr.id, actor: owner).approve!
    pr.reload
  end

  describe "GET /inventory/purchase_requests (list)" do
    it "shows request number, supplier, items count, total, status, created by/date, and receiving progress" do
      pr = build_request([ { product: product_a, quantity: 10, unit_price: 100, source_warehouse: warehouse } ])
      approve!(pr)

      sign_in owner
      get inventory_purchase_requests_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(pr.request_number)
      expect(response.body).to include("Acme")
      expect(response.body).to include(I18n.t("inventory.purchase_requests.statuses.approved"))
      expect(response.body).to include("1,000")
    end

    it "filters by status, supplier, and receiving status" do
      approved = build_request([ { product: product_a, quantity: 5, unit_price: 100, source_warehouse: warehouse } ])
      approve!(approved)
      draft = build_request([ { product: product_b, quantity: 3, unit_price: 200 } ])

      sign_in owner
      get inventory_purchase_requests_path(status: "draft")

      expect(response.body).to include(draft.request_number)
      expect(response.body).not_to include(approved.request_number)
    end

    it "searches by request number, supplier name, product name, and SKU" do
      pr = build_request([ { product: product_a, quantity: 5, unit_price: 100 } ])

      sign_in owner
      get inventory_purchase_requests_path(q: "A-1")
      expect(response.body).to include(pr.request_number)

      get inventory_purchase_requests_path(q: "nonexistent-sku")
      expect(response.body).not_to include(pr.request_number)
    end
  end

  describe "GET /inventory/purchase_requests/:id (details)" do
    it "shows requested/received/remaining per item and the receiving summary" do
      pr = build_request([ { product: product_a, quantity: 10, unit_price: 100, source_warehouse: warehouse } ])
      approve!(pr)

      sign_in owner
      get inventory_purchase_request_path(pr)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(t_num(10)) # requested
      expect(response.body).to include(I18n.t("inventory.purchase_requests.receiving_summary"))
    end
  end

  describe "GET /inventory/goods_receipts/new?purchase_request_id=" do
    it "prefills supplier, products, unit prices and remaining quantities without manual re-entry" do
      pr = build_request([
        { product: product_a, quantity: 10, unit_price: 100, source_warehouse: warehouse },
        { product: product_b, quantity: 5,  unit_price: 200, source_warehouse: warehouse }
      ])
      approve!(pr)

      sign_in owner
      get new_inventory_goods_receipt_path(purchase_request_id: pr.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Product A")
      expect(response.body).to include("Product B")
      expect(response.body).to include(I18n.t("inventory.goods_receipts.from_purchase_request"))
    end

    it "preselects the warehouse automatically when every item shares the same one" do
      pr = build_request([ { product: product_a, quantity: 10, unit_price: 100, source_warehouse: warehouse } ])
      approve!(pr)

      sign_in owner
      get new_inventory_goods_receipt_path(purchase_request_id: pr.id)

      expect(response.body).to match(/<option selected="selected" value="#{warehouse.id}">/)
    end

    it "does NOT guess the warehouse when items disagree — requires explicit selection" do
      pr = build_request([
        { product: product_a, quantity: 10, unit_price: 100, source_warehouse: warehouse },
        { product: product_b, quantity: 5,  unit_price: 200, source_warehouse: warehouse2 }
      ])
      approve!(pr)

      sign_in owner
      get new_inventory_goods_receipt_path(purchase_request_id: pr.id)

      expect(response.body).not_to match(/<option selected="selected" value="#{warehouse.id}">/)
      expect(response.body).not_to match(/<option selected="selected" value="#{warehouse2.id}">/)
    end

    it "requires the user to submit a warehouse before the receipt can be created (server-side, not just UI)" do
      pr = build_request([
        { product: product_a, quantity: 10, unit_price: 100, source_warehouse: warehouse },
        { product: product_b, quantity: 5,  unit_price: 200, source_warehouse: warehouse2 }
      ])
      approve!(pr)
      sign_in owner

      post inventory_goods_receipts_path, params: {
        goods_receipt: {
          purchase_request_id: pr.id, supplier_id: supplier.id, received_on: Date.current.to_s,
          funding_source_kind: "supplier_credit",
          items_attributes: { "0" => { product_id: product_a.id, quantity: 10, unit_cost: 100 } }
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(GoodsReceipt.where(purchase_request: pr).count).to eq(0)
    end

    it "refuses when the purchase request is still draft (not receivable)" do
      pr = build_request([ { product: product_a, quantity: 10, unit_price: 100 } ])

      sign_in owner
      get new_inventory_goods_receipt_path(purchase_request_id: pr.id)

      expect(response).to redirect_to(root_path)
    end

    it "refuses once the purchase request is fully received" do
      pr = build_request([ { product: product_a, quantity: 10, unit_price: 100, source_warehouse: warehouse } ])
      approve!(pr)
      receive!(pr, product_a, 10)
      expect(pr.reload).to be_fully_received

      sign_in owner
      get new_inventory_goods_receipt_path(purchase_request_id: pr.id)

      expect(response).to redirect_to(root_path)
    end

    it "refuses for a cancelled purchase request" do
      pr = build_request([ { product: product_a, quantity: 10, unit_price: 100 } ])
      approve!(pr)
      Inventory::PurchaseRequestCancellation.new(purchase_request_id: pr.id, actor: owner, reason: "no longer needed").call

      sign_in owner
      get new_inventory_goods_receipt_path(purchase_request_id: pr.id)

      expect(response).to redirect_to(root_path)
    end

    it "refuses for a rejected purchase request" do
      pr = build_request([ { product: product_a, quantity: 10, unit_price: 100 } ])
      pr.update_columns(status: "pending_approval", submitted_by_id: owner.id)
      Inventory::PurchaseRequestApproval.new(purchase_request_id: pr.id, actor: create(:user, business: business)).reject!(reason: "no")

      sign_in owner
      get new_inventory_goods_receipt_path(purchase_request_id: pr.id)

      expect(response).to redirect_to(root_path)
    end

    it "requires the create_goods_receipts permission (not create_purchase_requests)" do
      pr = build_request([ { product: product_a, quantity: 10, unit_price: 100, source_warehouse: warehouse } ])
      approve!(pr)

      role = business.permission_roles.create!(name: "PR only", permissions: %w[view_inventory create_purchase_requests])
      user = create(:user, business: business)
      user.update_column(:permission_role_id, role.id)
      sign_in user

      get new_inventory_goods_receipt_path(purchase_request_id: pr.id)
      expect(response).to redirect_to(root_path)
    end
  end

  describe "creating and confirming receipts against a Purchase Request" do
    it "does not change inventory when the receipt is created as a draft" do
      pr = build_request([ { product: product_a, quantity: 10, unit_price: 100, source_warehouse: warehouse } ])
      approve!(pr)
      sign_in owner

      expect {
        post inventory_goods_receipts_path, params: {
          goods_receipt: {
            purchase_request_id: pr.id, warehouse_id: warehouse.id, supplier_id: supplier.id,
            received_on: Date.current.to_s, funding_source_kind: "supplier_credit",
            items_attributes: { "0" => { product_id: product_a.id, quantity: 6, unit_cost: 100 } }
          }
        }
      }.not_to change(InventoryMovement, :count)

      expect(product_a.reload.current_stock).to eq(0)
      expect(pr.reload).to be_approved
    end

    it "supports partial receiving: first receipt moves the request to partially_received, links back, and only confirmation changes inventory" do
      pr = build_request([ { product: product_a, quantity: 10, unit_price: 100, source_warehouse: warehouse } ])
      approve!(pr)

      receipt = create_and_confirm_receipt!(pr, product_a, 6)

      expect(product_a.reload.current_stock).to eq(6)
      expect(pr.reload).to be_partially_received
      expect(receipt.purchase_request).to eq(pr)

      sign_in owner
      get inventory_goods_receipt_path(receipt)
      expect(response.body).to include(I18n.t("inventory.goods_receipts.original_purchase_request"))
      expect(response.body).to include(pr.request_number)

      get inventory_purchase_request_path(pr)
      expect(response.body).to include(receipt.receipt_number)
    end

    it "supports full receiving across two separate goods receipts for the same purchase request" do
      pr = build_request([ { product: product_a, quantity: 10, unit_price: 100, source_warehouse: warehouse } ])
      approve!(pr)

      create_and_confirm_receipt!(pr, product_a, 6)
      expect(pr.reload).to be_partially_received

      create_and_confirm_receipt!(pr, product_a, 4)
      expect(pr.reload).to be_fully_received
      expect(product_a.reload.current_stock).to eq(10)
      expect(pr.goods_receipts.count).to eq(2)
    end

    it "rejects a receipt quantity greater than the remaining quantity, with a clear error" do
      pr = build_request([ { product: product_a, quantity: 10, unit_price: 100, source_warehouse: warehouse } ])
      approve!(pr)
      create_and_confirm_receipt!(pr, product_a, 7) # remaining = 3
      pri = pr.items.find_by(product: product_a)

      sign_in owner
      post inventory_goods_receipts_path, params: {
        goods_receipt: {
          purchase_request_id: pr.id, warehouse_id: warehouse.id, supplier_id: supplier.id,
          received_on: Date.current.to_s, funding_source_kind: "supplier_credit",
          items_attributes: { "0" => { product_id: product_a.id, quantity: 5, unit_cost: 100,
                                       purchase_request_item_id: pri.id } }
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("3")
    end

    it "rejects a purchase-request-linked line that doesn't reference one of that request's items (can't bypass the remaining-quantity guard)" do
      pr = build_request([ { product: product_a, quantity: 10, unit_price: 100, source_warehouse: warehouse } ])
      approve!(pr)

      sign_in owner
      post inventory_goods_receipts_path, params: {
        goods_receipt: {
          purchase_request_id: pr.id, warehouse_id: warehouse.id, supplier_id: supplier.id,
          received_on: Date.current.to_s, funding_source_kind: "supplier_credit",
          items_attributes: { "0" => { product_id: product_a.id, quantity: 999, unit_cost: 100 } }
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(GoodsReceipt.where(purchase_request: pr).count).to eq(0)
    end

    it "handles multiple products with independently different received quantities" do
      pr = build_request([
        { product: product_a, quantity: 10, unit_price: 100, source_warehouse: warehouse },
        { product: product_b, quantity: 5,  unit_price: 200, source_warehouse: warehouse }
      ])
      approve!(pr)

      receive!(pr, product_a, 10)
      receive!(pr, product_b, 2)

      expect(pr.reload).to be_partially_received
      pri_a = pr.items.find_by(product: product_a)
      pri_b = pr.items.find_by(product: product_b)
      expect(pri_a.remaining_quantity).to eq(0)
      expect(pri_b.remaining_quantity).to eq(3)
    end
  end

  describe "historical goods receipts without a purchase request" do
    it "continue to work normally" do
      receipt = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
      receipt.items.build(product: product_a, quantity: 5, unit_cost: 20)
      receipt.save!
      receipt.update_column(:approval_status, "approved")

      result = Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: receipt.id, actor: owner).call
      expect(result.ok?).to be(true)
      expect(product_a.reload.current_stock).to eq(5)

      sign_in owner
      get inventory_goods_receipt_path(receipt)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(I18n.t("inventory.goods_receipts.original_purchase_request"))
    end
  end

  private

  def t_num(n)
    n.to_s
  end

  def create_and_confirm_receipt!(pr, product, quantity)
    pri = pr.items.find_by(product: product)
    receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current,
                                            purchase_request: pr)
    receipt.items.build(product: product, quantity: quantity, unit_cost: pri.unit_price, purchase_request_item: pri)
    receipt.save!
    receipt.update_column(:approval_status, "approved")
    result = Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: receipt.id, actor: owner).call
    raise "confirmation failed: #{result.error}" unless result.ok?

    receipt
  end
  alias_method :receive!, :create_and_confirm_receipt!
end
