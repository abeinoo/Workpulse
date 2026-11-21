require "rails_helper"

# Product availability per warehouse — Phase 1, unit 4: the low-stock engine
# honours availability state and separates detection from notification,
# while the legacy total alert for unconfigured products stays (decision N2).
RSpec.describe Inventory::LowStockQuery, "availability-aware" do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:central) { business.warehouses.create!(name: "Main Warehouse", kind: "central") }
  let!(:shubra)  { business.warehouses.create!(name: "Shoubra WH", kind: "central") }

  def product(sku, tracked: true, legacy_level: 10)
    business.products.create!(name: "Product #{sku}", sku: sku, initial_cost_price: 5, average_cost_price: 5,
                              track_inventory: tracked, low_stock_level: legacy_level, reorder_level: legacy_level, reorder_quantity: 20)
  end

  def receive(product, warehouse, quantity)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: product, quantity: quantity, unit_cost: 5)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  def manager = Inventory::ProductAvailabilityManager.new(actor: owner)

  def configure(product, warehouse, low:, reorder: 10, notify: true)
    manager.add_many(warehouse_id: warehouse.id,
                     items: [ { product_id: product.id, low_stock_level: low, reorder_quantity: reorder, receive_low_stock_notification: notify } ])
    ProductWarehouseSetting.find_by!(product: product, warehouse: warehouse)
  end

  def alerts = described_class.new(business).alerts

  it "never evaluates an Inactive pair, while the product's Active pairs still alert" do
    shampoo = product("SH-1")
    receive(shampoo, central, 8)
    configure(shampoo, central, low: 10)
    shubra_row = configure(shampoo, shubra, low: 3)
    manager.deactivate(setting_id: shubra_row.id, reason: "not used in Shoubra")

    expect(alerts.map { |a| [ a.product, a.warehouse_id ] }).to eq([ [ shampoo, central.id ] ])
  end

  it "a product whose every pair is Inactive gets no alert at all — not the legacy total alert" do
    mask = product("MK-1", legacy_level: 10) # legacy total check would fire at stock 0
    row = configure(mask, central, low: 5)
    manager.deactivate(setting_id: row.id, reason: "discontinued here")

    expect(alerts).to be_empty
  end

  it "detection does not depend on the notification switch; the alert says whether to notify" do
    shampoo = product("SH-1")
    receive(shampoo, central, 2)
    configure(shampoo, central, low: 3, notify: false)

    alert = alerts.sole
    expect([ alert.warehouse_id, alert.on_hand, alert.low_stock_level ]).to eq([ central.id, 2, 3 ])
    expect(alert).not_to be_notifiable

    ProductWarehouseSetting.find_by!(product: shampoo).update!(receive_low_stock_notification: true)
    expect(alerts.sole).to be_notifiable
  end

  it "keeps the legacy total alert for an unconfigured product (transition, N2) — marked notifiable" do
    legacy = product("LG-1", legacy_level: 10)
    receive(legacy, central, 4)

    alert = alerts.sole
    expect(alert).to be_total
    expect(alert).to be_notifiable
    expect(alert.low_stock_level).to eq(10)
  end

  it "a branch warehouse without a row never inherits the central settings" do
    shampoo = product("SH-1")
    receive(shampoo, central, 50)
    configure(shampoo, central, low: 10)
    # Shoubra has no row and no stock: Not Configured, not monitored, no inherited threshold.
    expect(alerts).to be_empty
  end

  it "does not detect an untracked product even with an Active pair" do
    towel = product("TW-1", tracked: false, legacy_level: 0)
    ProductWarehouseSetting.create!(product: towel, warehouse: central) # pre-existing row (no new ones now)
    expect(ProductWarehouseSetting.find_by!(product: towel)).to be_status_active
    expect(alerts).to be_empty
  end
end
