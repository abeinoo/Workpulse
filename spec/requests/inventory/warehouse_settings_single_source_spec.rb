require "rails_helper"

# Low-stock threshold, reorder quantity and the low-stock notification are
# per warehouse only (ProductWarehouseSetting). The same product has
# independent settings in the Central warehouse and in a branch; every
# low-stock / reorder surface uses each warehouse's own values, a warehouse
# without a setting falls back to nothing (not to the stale values still
# stored in the retired product columns), and browsing changes no setting.
RSpec.describe "Warehouse settings are the single source of low-stock and reorder values", type: :request do
  let(:business)  { create(:business) }
  let!(:owner)    { create(:user, :owner, business: business) }
  let!(:central)  { business.warehouses.create!(name: "Central WH", kind: "central") }
  let!(:branch)   { business.warehouses.create!(name: "Nasr City WH", kind: "branch", branch: create(:branch, business: business)) }
  let!(:outlet)   { business.warehouses.create!(name: "Outlet WH", kind: "central") }
  let(:manager)   { Inventory::ProductAvailabilityManager.new(actor: owner) }
  let!(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
            .tap { |p| write_retired_product_stock_columns!(p, low_stock_level: 500, reorder_quantity: 999, reorder_level: 500) }
  end

  def stock!(warehouse, qty)
    InventoryMovement.create!(business: business, product: product, warehouse: warehouse, direction: :in,
                              quantity: qty, unit_cost: 10, reason: :adjustment, occurred_on: Date.current)
  end

  def settings_snapshot
    ProductWarehouseSetting.order(:id).pluck(:id, :warehouse_id, :status, :low_stock_level, :reorder_quantity,
                                             :receive_low_stock_notification, :updated_at)
  end

  # { warehouse_id => reorder quantity } of the Low Stock rows in the page.
  def low_stock_rows
    Nokogiri::HTML(response.body).css(".low-stock-check-row")
            .to_h { |box| [ box["data-warehouse-id"].to_i, box["data-reorder-qty"].to_d ] }
  end

  before do
    expect(manager.save_settings(product_id: product.id, warehouse_id: central.id, low_stock_level: 40, reorder_quantity: 100)).to be_ok
    expect(manager.save_settings(product_id: product.id, warehouse_id: branch.id, low_stock_level: 4, reorder_quantity: 6)).to be_ok
    stock!(central, 30) # 30 ≤ 40 → low in Central
    stock!(branch, 3)   # 3 ≤ 4   → low in the branch
    stock!(outlet, 1)   # no setting in Outlet: never low (the stale 500 is ignored)
    sign_in owner
  end

  it "alerts and suggests per warehouse, with each warehouse's own values and nothing for an unconfigured one" do
    alerts = Inventory::LowStockQuery.new(business).alerts
    expect(alerts.to_h { |a| [ a.warehouse_id, [ a.on_hand, a.low_stock_level, a.reorder_quantity ] ] })
      .to eq(central.id => [ 30, 40, 100 ], branch.id => [ 3, 4, 6 ])

    get inventory_low_stock_report_path
    expect(low_stock_rows).to eq(central.id => 100, branch.id => 6)

    get inventory_root_path
    expect(low_stock_rows).to eq(central.id => 100, branch.id => 6)
  end

  it "the warehouse's own threshold decides: raising one warehouse's stock clears only that warehouse" do
    stock!(branch, 10)
    expect(Inventory::LowStockQuery.new(business).alerts.map(&:warehouse_id)).to eq([ central.id ])
  end

  it "every page that shows low-stock or reorder values leaves every warehouse setting unchanged" do
    before = settings_snapshot
    [ inventory_root_path, root_path, inventory_low_stock_report_path, inventory_products_path,
      inventory_product_path(product), edit_inventory_product_path(product), new_inventory_purchase_request_path,
      inventory_warehouse_product_availabilities_path(central), inventory_warehouse_product_availabilities_path(branch),
      inventory_availability_reconciliation_path ].each do |path|
      get path
      expect(response).to have_http_status(:ok), path
    end
    expect(settings_snapshot).to eq(before)
    expect(retired_product_stock_columns(product).slice("low_stock_level", "reorder_quantity")).to eq("low_stock_level" => 500, "reorder_quantity" => 999)
  end

  it "editing one warehouse's settings changes that warehouse only" do
    central_row = ProductWarehouseSetting.find_by!(warehouse: central)
    branch_before = ProductWarehouseSetting.find_by!(warehouse: branch).attributes
    expect(manager.update(setting_id: central_row.id, low_stock_level: 10, reorder_quantity: 20,
                          receive_low_stock_notification: false)).to be_ok

    expect(central_row.reload).to have_attributes(low_stock_level: 10, reorder_quantity: 20, receive_low_stock_notification: false)
    expect(ProductWarehouseSetting.find_by!(warehouse: branch).attributes).to eq(branch_before)
    expect(ProductWarehouseSetting.where(warehouse: outlet)).to be_empty
  end
end
