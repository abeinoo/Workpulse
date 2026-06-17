require "rails_helper"

RSpec.describe "Main dashboard inventory low-stock widget", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }
  let!(:wh)      { business.warehouses.create!(name: "Main") }
  let!(:product) do
    business.products.create!(name: "LowItem", sku: "LOW-1", initial_cost_price: 10,
                              average_cost_price: 10, low_stock_level: 5, reorder_level: 5, reorder_quantity: 20)
  end

  before do
    r = business.goods_receipts.build(warehouse: wh, received_on: Date.current)
    r.items.build(product: product, quantity: 3, unit_cost: 10) # below low_stock_level of 5
    Inventory::GoodsReceiptPoster.new(r).call
  end

  it "shows the low-stock widget to an inventory user" do
    sign_in owner
    get root_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("dashboard.inventory.low_stock_title"))
    expect(response.body).to include("LowItem")
  end

  it "hides the widget from a user without inventory access" do
    employee = create(:user, business: business)
    sign_in employee
    get root_path
    expect(response.body).not_to include(I18n.t("dashboard.inventory.low_stock_title"))
  end

  it "scopes the widget to the manager's warehouse" do
    other_wh = business.warehouses.create!(name: "Other")
    other_product = business.products.create!(name: "OtherLow", sku: "OL-1", initial_cost_price: 1,
                                              average_cost_price: 1, low_stock_level: 5, reorder_level: 5)
    r = business.goods_receipts.build(warehouse: other_wh, received_on: Date.current)
    r.items.build(product: other_product, quantity: 1, unit_cost: 1)
    Inventory::GoodsReceiptPoster.new(r).call

    role = business.permission_roles.create!(name: "Mgr", permissions: %w[view_inventory])
    manager = create(:user, business: business)
    manager.update_column(:permission_role_id, role.id)
    manager.assigned_warehouses << wh

    sign_in manager
    get root_path
    expect(response.body).to include("LowItem")       # in their warehouse
    expect(response.body).not_to include("OtherLow")  # other warehouse — hidden
  end
end
