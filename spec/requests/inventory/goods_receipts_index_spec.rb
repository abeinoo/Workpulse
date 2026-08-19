require "rails_helper"

RSpec.describe "Goods receipts index — filters", type: :request do
  let(:business)     { create(:business) }
  let(:owner)        { create(:user, :owner, business: business) }
  let(:warehouse_a)  { business.warehouses.create!(name: "Warehouse A") }
  let(:warehouse_b)  { business.warehouses.create!(name: "Warehouse B") }
  let(:supplier_a)   { business.suppliers.create!(name: "Supplier A") }
  let(:supplier_b)   { business.suppliers.create!(name: "Supplier B") }
  let(:product) do
    business.products.create!(name: "Widget", sku: "W-1", initial_cost_price: 0, average_cost_price: 0)
  end

  let!(:owner_account) do
    account = create(:custody_account, business: business, user: owner)
    account.custody_transactions.create!(business: business, txn_type: "top_up", amount: 100_000)
    account.refresh_balance!
    account
  end

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def receive!(warehouse: warehouse_a, supplier: nil, received_on: Date.current)
    post inventory_goods_receipts_path, params: {
      goods_receipt: {
        warehouse_id: warehouse.id, supplier_id: supplier&.id, received_on: received_on,
        funding_source_kind: "employee_custody",
        items_attributes: { "0" => { product_id: product.id, quantity: 1, unit_cost: 10 } }
      }
    }
    business.goods_receipts.order(:created_at).last
  end

  before { sign_in owner }

  describe "no filters" do
    it "shows all authorized receipts" do
      a = receive!(warehouse: warehouse_a)
      b = receive!(warehouse: warehouse_b)

      get inventory_goods_receipts_path

      expect(response.body).to include(a.receipt_number)
      expect(response.body).to include(b.receipt_number)
    end
  end

  describe "warehouse filter" do
    it "shows only receipts from the selected warehouse" do
      a = receive!(warehouse: warehouse_a)
      b = receive!(warehouse: warehouse_b)

      get inventory_goods_receipts_path, params: { warehouse_id: warehouse_a.id }

      expect(response.body).to include(a.receipt_number)
      expect(response.body).not_to include(b.receipt_number)
    end

    it "handles a non-existent warehouse id safely, returning no results rather than erroring" do
      receive!(warehouse: warehouse_a)

      get inventory_goods_receipts_path, params: { warehouse_id: 999_999 }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("inventory.goods_receipts.empty"))
    end

    it "restricts the dropdown to warehouses the current user is assigned to" do
      scoped_user = user_with("view_inventory")
      WarehouseAssignment.create!(user: scoped_user, warehouse: warehouse_a)
      sign_in scoped_user

      get inventory_goods_receipts_path

      expect(response.body).to include(warehouse_a.name)
      expect(response.body).not_to include(warehouse_b.name)
    end

    it "does not leak receipts from an unauthorized warehouse when the id is manipulated in the URL" do
      other_warehouse_receipt = receive!(warehouse: warehouse_b)

      scoped_user = user_with("view_inventory")
      WarehouseAssignment.create!(user: scoped_user, warehouse: warehouse_a)
      sign_in scoped_user

      get inventory_goods_receipts_path, params: { warehouse_id: warehouse_b.id }

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(other_warehouse_receipt.receipt_number)
      expect(response.body).to include(I18n.t("inventory.goods_receipts.empty"))
    end
  end

  describe "approval status filter" do
    it "shows only receipts with the selected approval status" do
      draft    = receive!
      pending  = receive!
      post submit_inventory_goods_receipt_path(pending)

      get inventory_goods_receipts_path, params: { approval_status: "pending_approval" }

      expect(response.body).to include(pending.receipt_number)
      expect(response.body).not_to include(draft.receipt_number)
    end

    it "does not raise on a tampered/unknown approval_status value" do
      receive!

      get inventory_goods_receipts_path, params: { approval_status: "not_a_real_status" }

      expect(response).to have_http_status(:ok)
    end
  end

  describe "receiving status filter" do
    it "shows only received receipts when receiving_status=received" do
      not_received = receive!
      to_confirm   = receive!
      post submit_inventory_goods_receipt_path(to_confirm)
      post approve_inventory_goods_receipt_path(to_confirm) # owner bypasses self-approval
      post confirm_inventory_goods_receipt_path(to_confirm)

      get inventory_goods_receipts_path, params: { receiving_status: "received" }

      expect(response.body).to include(to_confirm.receipt_number)
      expect(response.body).not_to include(not_received.receipt_number)
    end

    it "shows only not-received receipts when receiving_status=not_received" do
      not_received = receive!
      to_confirm   = receive!
      post submit_inventory_goods_receipt_path(to_confirm)
      post approve_inventory_goods_receipt_path(to_confirm)
      post confirm_inventory_goods_receipt_path(to_confirm)

      get inventory_goods_receipts_path, params: { receiving_status: "not_received" }

      expect(response.body).to include(not_received.receipt_number)
      expect(response.body).not_to include(to_confirm.receipt_number)
    end
  end

  describe "supplier filter" do
    it "shows only receipts from the selected supplier" do
      a = receive!(supplier: supplier_a)
      b = receive!(supplier: supplier_b)

      get inventory_goods_receipts_path, params: { supplier_id: supplier_a.id }

      expect(response.body).to include(a.receipt_number)
      expect(response.body).not_to include(b.receipt_number)
    end
  end

  describe "date range filter" do
    it "shows only receipts within the selected date range" do
      old_receipt    = receive!(received_on: 10.days.ago.to_date)
      recent_receipt = receive!(received_on: Date.current)

      get inventory_goods_receipts_path, params: {
        date_from: 3.days.ago.to_date.iso8601, date_to: Date.current.iso8601
      }

      expect(response.body).to include(recent_receipt.receipt_number)
      expect(response.body).not_to include(old_receipt.receipt_number)
    end
  end

  describe "combined filters" do
    it "returns only receipts matching every selected condition (AND, not OR)" do
      matching = receive!(warehouse: warehouse_a, supplier: supplier_a)
      post submit_inventory_goods_receipt_path(matching)
      post approve_inventory_goods_receipt_path(matching)

      wrong_warehouse = receive!(warehouse: warehouse_b, supplier: supplier_a)
      post submit_inventory_goods_receipt_path(wrong_warehouse)
      post approve_inventory_goods_receipt_path(wrong_warehouse)

      wrong_supplier = receive!(warehouse: warehouse_a, supplier: supplier_b)
      post submit_inventory_goods_receipt_path(wrong_supplier)
      post approve_inventory_goods_receipt_path(wrong_supplier)

      get inventory_goods_receipts_path, params: {
        warehouse_id: warehouse_a.id, supplier_id: supplier_a.id, approval_status: "approved"
      }

      expect(response.body).to include(matching.receipt_number)
      expect(response.body).not_to include(wrong_warehouse.receipt_number)
      expect(response.body).not_to include(wrong_supplier.receipt_number)
    end
  end

  describe "reset filters" do
    it "shows all authorized receipts again after clearing filters" do
      a = receive!(warehouse: warehouse_a)
      b = receive!(warehouse: warehouse_b)

      get inventory_goods_receipts_path, params: { warehouse_id: warehouse_a.id }
      expect(response.body).not_to include(b.receipt_number)

      get inventory_goods_receipts_path
      expect(response.body).to include(a.receipt_number)
      expect(response.body).to include(b.receipt_number)
    end
  end

  describe "results count" do
    it "reflects the filtered result count, not the total" do
      receive!(warehouse: warehouse_a)
      receive!(warehouse: warehouse_a)
      receive!(warehouse: warehouse_b)

      get inventory_goods_receipts_path, params: { warehouse_id: warehouse_a.id }

      expect(response.body).to include(I18n.t("inventory.goods_receipts.results_count", count: 2))
    end
  end

  describe "existing behavior unchanged" do
    it "still renders the receipts table with all documented columns" do
      receipt = receive!(warehouse: warehouse_a, supplier: supplier_a)

      get inventory_goods_receipts_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(receipt.receipt_number)
      expect(response.body).to include(I18n.t("inventory.goods_receipts.number"))
      expect(response.body).to include(I18n.t("inventory.goods_receipts.date"))
      expect(response.body).to include(I18n.t("inventory.goods_receipts.supplier"))
      expect(response.body).to include(I18n.t("inventory.goods_receipts.warehouse"))
      expect(response.body).to include(I18n.t("inventory.goods_receipts.approval_status"))
      expect(response.body).to include(I18n.t("inventory.goods_receipts.receipt_status"))
      expect(response.body).to include(I18n.t("inventory.goods_receipts.total"))
    end
  end
end
