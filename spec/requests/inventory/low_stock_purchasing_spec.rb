require "rails_helper"

RSpec.describe "Inventory dashboard low-stock purchasing table", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }
  let!(:wh)      { business.warehouses.create!(name: "Main") }

  let!(:priced_product) do
    business.products.create!(name: "PricedItem", sku: "PRC-1", initial_cost_price: 150,
                               average_cost_price: 150, low_stock_level: 5, reorder_level: 5,
                               reorder_quantity: 12)
  end

  let!(:unpriced_product) do
    business.products.create!(name: "UnpricedItem", sku: "UNP-1", initial_cost_price: 0,
                               average_cost_price: 0, low_stock_level: 5, reorder_level: 5,
                               reorder_quantity: 7)
  end

  before do
    [ priced_product, unpriced_product ].each do |product|
      r = business.goods_receipts.build(warehouse: wh, received_on: Date.current)
      r.items.build(product: product, quantity: 1, unit_cost: product.average_cost_price)
      Inventory::GoodsReceiptPoster.new(r).call
    end
  end

  it "shows checkboxes, unit price, row total (reorder_quantity * unit_price), and handles missing prices safely" do
    sign_in owner
    get inventory_root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("PricedItem")
    expect(response.body).to include("UnpricedItem")

    # Row total uses reorder_quantity (12), not current stock (1): 12 * 150 = 1800
    expect(response.body).to include(I18n.t("inventory.dashboard.selected_total"))
    expect(response.body).to include("low-stock-check-row")
    expect(response.body).to include("low-stock-check-all")
    expect(response.body).to include('data-amount="1800.0"')
    expect(response.body).to include('data-amount="0"')
    expect(response.body).to include(I18n.t("inventory.dashboard.price_not_set"))
  end

  it "shows the disabled Create Purchase Request button, gated by permission, with per-row supplier data" do
    supplier = business.suppliers.create!(name: "Acme Supplies")
    priced_product.update!(default_supplier: supplier)

    sign_in owner
    get inventory_root_path

    expect(response.body).to include(I18n.t("inventory.dashboard.create_purchase_request"))
    expect(response.body).to match(/data-low-stock-selection-target="createBtn"[\s\S]*?disabled>/)
    expect(response.body).to include('data-supplier-id="' + supplier.id.to_s + '"')
    expect(response.body).to include('data-supplier-name="Acme Supplies"')
    # Unpriced/no-default-supplier product still renders the row with an empty supplier hint.
    expect(response.body).to include('data-supplier-id=""')
  end

  it "hides the Create Purchase Request button from a user without permission" do
    role = business.permission_roles.create!(name: "Viewer", permissions: %w[view_inventory])
    viewer = create(:user, business: business)
    viewer.update_column(:permission_role_id, role.id)

    sign_in viewer
    get inventory_root_path

    expect(response.body).not_to include('data-low-stock-selection-target="createBtn"')
  end
end
