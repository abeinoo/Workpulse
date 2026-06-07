require "rails_helper"

RSpec.describe "Inventory", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }

  let(:manager) do
    role = business.permission_roles.create!(name: "Inv Manager",
                                             permissions: %w[view_inventory manage_inventory])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:accountant) do
    role = business.permission_roles.create!(name: "Inv Accountant",
                                             permissions: %w[view_inventory_reports])
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:employee) { create(:user, business: business) }

  describe "access control" do
    it "denies a plain employee" do
      sign_in employee
      get inventory_root_path
      expect(response).to redirect_to(root_path)
    end

    it "allows the inventory manager" do
      sign_in manager
      get inventory_root_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "index pages render" do
    before { sign_in owner }

    %i[
      inventory_root_path inventory_warehouses_path inventory_suppliers_path
      inventory_brands_path inventory_product_categories_path inventory_products_path
      inventory_goods_receipts_path inventory_stock_issues_path
    ].each do |path_helper|
      it "GET #{path_helper} returns 200" do
        get public_send(path_helper)
        expect(response).to have_http_status(:ok)
      end
    end

    it "renders the new-product and new-receipt forms" do
      get new_inventory_product_path
      expect(response).to have_http_status(:ok)
      get new_inventory_goods_receipt_path
      expect(response).to have_http_status(:ok)
      get new_inventory_stock_issue_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "creating records end-to-end" do
    before { sign_in owner }

    it "creates a warehouse, product, posts a receipt, then a stock issue" do
      post inventory_warehouses_path, params: { warehouse: { name: "Main", status: "active" } }
      warehouse = business.warehouses.find_by!(name: "Main")

      post inventory_products_path, params: {
        product: { name: "Shampoo", sku: "SH-1", initial_cost_price: 10, low_stock_level: 2 }
      }
      product = business.products.find_by!(sku: "SH-1")

      post inventory_goods_receipts_path, params: {
        goods_receipt: {
          warehouse_id: warehouse.id, received_on: Date.current,
          items_attributes: { "0" => { product_id: product.id, quantity: 10, unit_cost: 12 } }
        }
      }
      expect(business.goods_receipts.count).to eq(1)
      expect(product.reload.current_stock).to eq(10)
      expect(product.average_cost_price).to eq(12)

      post inventory_stock_issues_path, params: {
        stock_issue: {
          warehouse_id: warehouse.id, issued_on: Date.current,
          items_attributes: { "0" => { product_id: product.id, quantity: 3 } }
        }
      }
      expect(business.stock_issues.count).to eq(1)
      expect(product.reload.current_stock).to eq(7)
    end

    it "rejects an over-issue and creates no stock issue" do
      post inventory_warehouses_path, params: { warehouse: { name: "Main", status: "active" } }
      warehouse = business.warehouses.find_by!(name: "Main")
      post inventory_products_path, params: { product: { name: "Mask", sku: "MK-1", initial_cost_price: 5 } }
      product = business.products.find_by!(sku: "MK-1")

      post inventory_stock_issues_path, params: {
        stock_issue: {
          warehouse_id: warehouse.id, issued_on: Date.current,
          items_attributes: { "0" => { product_id: product.id, quantity: 5 } }
        }
      }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(business.stock_issues.count).to eq(0)
    end
  end

  describe "accountant (reports-only) access" do
    before { sign_in accountant }

    it "can reach the inventory dashboard" do
      get inventory_root_path
      expect(response).to have_http_status(:ok)
    end

    it "cannot create a warehouse" do
      post inventory_warehouses_path, params: { warehouse: { name: "X", status: "active" } }
      expect(response).to redirect_to(root_path)
      expect(business.warehouses.count).to eq(0)
    end
  end
end
