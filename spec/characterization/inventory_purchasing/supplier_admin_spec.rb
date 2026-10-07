require "rails_helper"

# Characterization (Pilot 6 — Inventory & Purchasing Supplier, M1) — CURRENT
# behaviour of supplier administration (Inventory::SuppliersController +
# SupplierPolicy). Cross-business references from receipts and products and the
# supplier page's receipt summary are pinned by the M0 security regression specs
# in spec/requests/security/ (SEC-P6-1/2/3) and not repeated here.
#
# Requests that end in a rescued 404 are kept one per example.
RSpec.describe "Characterization: supplier administration", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:supplier)         { business.suppliers.create!(name: "Beta Supplies", primary_mobile: "0500000001") }
  let!(:foreign_supplier) { other.suppliers.create!(name: "Foreign Supplies") }

  let(:viewer)       { api_user_with(business, :view_inventory) }
  let(:manager)      { api_user_with(business, :view_inventory, :manage_inventory) }
  let(:supplier_mgr) { api_user_with(business, :view_inventory, :manage_suppliers) }
  let(:reports_only) { api_user_with(business, :view_inventory_reports) }
  let(:employee)     { create(:user, business: business) }

  def valid_params(name = "Gamma Supplies") = { supplier: { name: name, primary_mobile: "0511111111", address: "Riyadh" } }

  def expect_denied
    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
  end

  describe "CRUD (manage_inventory)" do
    before { sign_in manager }

    it "index lists the business's suppliers ordered by name, never another business's" do
      business.suppliers.create!(name: "Alpha Supplies")
      get inventory_suppliers_path

      expect(response).to have_http_status(:ok)
      expect(response.body.index("Alpha Supplies")).to be < response.body.index("Beta Supplies")
      expect(response.body).not_to include("Foreign Supplies")
    end

    it "show, new and edit render" do
      get inventory_supplier_path(supplier)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Beta Supplies", "0500000001")

      get new_inventory_supplier_path
      expect(response).to have_http_status(:ok)
      get edit_inventory_supplier_path(supplier)
      expect(response).to have_http_status(:ok)
    end

    it "creates a supplier in the actor's business and redirects to it" do
      expect { post inventory_suppliers_path, params: valid_params }.to change(business.suppliers, :count).by(1)

      created = business.suppliers.find_by!(name: "Gamma Supplies")
      expect(response).to redirect_to(inventory_supplier_path(created))
      expect(created).to have_attributes(primary_mobile: "0511111111", address: "Riyadh")
    end

    it "re-renders 422 for a blank name, an over-long name or mobile, and out-of-range coordinates" do
      [ { name: "" }, { name: "x" * 151 }, { name: "Ok", primary_mobile: "9" * 31 }, { name: "Ok", latitude: 91 },
        { name: "Ok", longitude: -181 } ].each do |attrs|
        expect { post inventory_suppliers_path, params: { supplier: attrs } }.not_to change(Supplier, :count)
        expect(response).to have_http_status(:unprocessable_entity), attrs.inspect
      end
    end

    it "allows duplicate names within a business (no uniqueness rule)" do
      post inventory_suppliers_path, params: valid_params("Beta Supplies")
      expect(business.suppliers.where(name: "Beta Supplies").count).to eq(2)
    end

    it "updates, and re-renders 422 on an invalid update" do
      patch inventory_supplier_path(supplier), params: { supplier: { name: "Beta Renamed" } }
      expect(response).to redirect_to(inventory_supplier_path(supplier))
      expect(supplier.reload.name).to eq("Beta Renamed")

      patch inventory_supplier_path(supplier), params: { supplier: { name: "" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(supplier.reload.name).to eq("Beta Renamed")
    end

    it "ignores a submitted business_id" do
      post inventory_suppliers_path, params: { supplier: { name: "Placed", business_id: other.id } }
      expect(Supplier.find_by!(name: "Placed").business_id).to eq(business.id)
    end
  end

  describe "destroy" do
    let(:warehouse) { business.warehouses.create!(name: "Main") }
    let(:product)   { business.products.create!(name: "Dye", sku: "DY-1", initial_cost_price: 1, average_cost_price: 1) }

    before { sign_in manager }

    it "deletes an unreferenced supplier" do
      delete inventory_supplier_path(supplier)

      expect(response).to redirect_to(inventory_suppliers_path)
      expect(Supplier).not_to exist(supplier.id)
    end

    it "refuses a supplier with goods receipts (restrict_with_error) and keeps it" do
      receipt = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current)
      receipt.items.build(product: product, quantity: 1, unit_cost: 1)
      Inventory::GoodsReceiptPoster.new(receipt).call

      delete inventory_supplier_path(supplier)

      expect(response).to redirect_to(inventory_suppliers_path)
      expect(flash[:alert]).to be_present
      expect(Supplier).to exist(supplier.id)
    end

    it "P6-D1 (known defect, pinned): a supplier that is a product's default raises InvalidForeignKey (500)" do
      product.update!(default_supplier: supplier)

      expect { delete inventory_supplier_path(supplier) }.to raise_error(ActiveRecord::InvalidForeignKey)
      expect(Supplier).to exist(supplier.id)
    end

    it "P6-D1 (known defect, pinned): a supplier with a purchase request raises InvalidForeignKey (500)" do
      business.purchase_requests.create!(supplier: supplier, items_attributes: [ { product_id: product.id, quantity: 1, unit_price: 1 } ])

      expect { delete inventory_supplier_path(supplier) }.to raise_error(ActiveRecord::InvalidForeignKey)
      expect(Supplier).to exist(supplier.id)
    end
  end

  describe "authorization (SupplierPolicy behind the inventory gate)" do
    it "view_inventory: may list and view; may not create, update or delete" do
      sign_in viewer
      get inventory_suppliers_path
      expect(response).to have_http_status(:ok)
      get inventory_supplier_path(supplier)
      expect(response).to have_http_status(:ok)

      expect { post inventory_suppliers_path, params: valid_params }.not_to change(Supplier, :count)
      expect_denied
      patch inventory_supplier_path(supplier), params: { supplier: { name: "Hacked" } }
      expect_denied
      delete inventory_supplier_path(supplier)
      expect_denied
      expect(supplier.reload.name).to eq("Beta Supplies")
    end

    it "manage_suppliers (with its view_inventory dependency): full administration" do
      sign_in supplier_mgr
      post inventory_suppliers_path, params: valid_params
      patch inventory_supplier_path(supplier), params: { supplier: { name: "Beta Renamed" } }
      created = business.suppliers.find_by!(name: "Gamma Supplies")
      delete inventory_supplier_path(created)

      expect(supplier.reload.name).to eq("Beta Renamed")
      expect(Supplier).not_to exist(created.id)
    end

    it "the owner has full access" do
      sign_in owner
      post inventory_suppliers_path, params: valid_params
      expect(business.suppliers.where(name: "Gamma Supplies")).to exist
    end

    it "a reports-only user passes the inventory gate but not SupplierPolicy#index?" do
      sign_in reports_only
      get inventory_suppliers_path
      expect_denied
    end

    it "a user without any inventory permission is stopped by the inventory gate" do
      sign_in employee
      get inventory_suppliers_path
      expect_denied
    end
  end

  describe "business isolation (404, nothing changed)" do
    before { sign_in manager }

    it "cannot view another business's supplier" do
      get inventory_supplier_path(foreign_supplier)
      expect(response).to have_http_status(:not_found)
    end

    it "cannot open another business's edit form" do
      get edit_inventory_supplier_path(foreign_supplier)
      expect(response).to have_http_status(:not_found)
    end

    it "cannot update another business's supplier" do
      patch inventory_supplier_path(foreign_supplier), params: { supplier: { name: "Hacked" } }
      expect(response).to have_http_status(:not_found)
      expect(foreign_supplier.reload.name).to eq("Foreign Supplies")
    end

    it "cannot delete another business's supplier" do
      delete inventory_supplier_path(foreign_supplier)
      expect(response).to have_http_status(:not_found)
      expect(Supplier).to exist(foreign_supplier.id)
    end
  end
end
