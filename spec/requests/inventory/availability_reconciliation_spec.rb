require "rails_helper"

# Phase 2: the read-only reconciliation page.
RSpec.describe "Availability reconciliation report", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:central) { business.warehouses.create!(name: "Main Warehouse", kind: "central") }
  let!(:product) { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 1, average_cost_price: 1) }

  it "renders every section for a manager, read-only, and changes nothing" do
    InventoryMovement.create!(business: business, product: product, warehouse: central, direction: :in, quantity: 3,
                              unit_cost: 1, reason: :adjustment, occurred_on: Date.current)
    sign_in owner
    before = [ ProductWarehouseSetting.count, InventoryMovement.count, AuditLog.count ]

    get inventory_availability_reconciliation_path

    expect(response).to have_http_status(:ok)
    body = response.body
    expect(body).to include(ERB::Util.html_escape(I18n.t("product_availability.reconciliation.read_only")))
    expect(body).to include(%(data-testid="central-target"))
    # The central warehouse includes the product by default: its stock is not "without a row".
    expect(body).not_to include(%(data-testid="stock_without_row-#{product.id}-#{central.id}"))
    expect(Nokogiri::HTML(body).at_css("[data-testid='central-candidate-#{central.id}']")).to be_present
    expect([ ProductWarehouseSetting.count, InventoryMovement.count, AuditLog.count ]).to eq(before)
  end

  it "has no product-level (legacy) section and ignores stale product-level values" do
    write_retired_product_stock_columns!(product, low_stock_level: 7, reorder_quantity: 30, reorder_level: 4)
    sign_in owner
    get inventory_availability_reconciliation_path
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("legacy-#{product.id}", "legacy-total-alert-count", "transfer-summary")
    expect(response.body).not_to match(/legacy|Legacy|transfer to central/i)
  end

  it "names every central warehouse and does not guess when there are several" do
    old_central = business.warehouses.create!(name: "Old Central", kind: "central")
    sign_in owner
    get inventory_availability_reconciliation_path
    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css("[data-testid='central-list']").text).to include("Main Warehouse", "Old Central")
    expect(doc.at_css("[data-testid='central-candidate-#{old_central.id}']")).to be_present
    expect(doc.at_css("[data-testid='central-undetermined']")).to be_present
    expect(doc.at_css("[data-testid='central-target']")).to be_nil
  end

  it "is linked from the warehouses page only for users who manage availability" do
    sign_in owner
    get inventory_warehouses_path
    expect(response.body).to include(%(data-testid="availability-reconciliation-link"))
  end

  it "is refused without manage_product_availability" do
    viewer = user_with_stock_permissions(business, :view_inventory, :manage_inventory, name: "Inventory")
    sign_in viewer
    get inventory_warehouses_path
    expect(response.body).not_to include(%(data-testid="availability-reconciliation-link"))
    get inventory_availability_reconciliation_path
    expect(response).to redirect_to(root_path)
  end

  it "renders in Arabic" do
    owner.update!(preferred_locale: "ar")
    sign_in owner
    get inventory_availability_reconciliation_path
    expect(response.body).to include('dir="rtl"', "مطابقة توفر المنتجات")
    expect(response.body).not_to include("translation missing")
  end
end
