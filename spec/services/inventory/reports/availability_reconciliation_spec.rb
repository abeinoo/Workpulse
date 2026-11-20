require "rails_helper"

# Phase 2: the read-only availability reconciliation report. It reports;
# it never writes (no rows, no statuses, no movements).
RSpec.describe Inventory::Reports::AvailabilityReconciliation do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:central) { business.warehouses.create!(name: "Main Warehouse", kind: "central") }
  let!(:branch_record) { create(:branch, business: business, name: "Nasr City") }
  let!(:branch_wh) do
    Warehouse.find_by(branch: branch_record) || business.warehouses.create!(name: "Nasr City WH", kind: "branch", branch: branch_record)
  end
  let(:manager) { Inventory::ProductAvailabilityManager.new(actor: owner) }

  def product(name, sku, **attrs)
    business.products.create!(name: name, sku: sku, initial_cost_price: 1, average_cost_price: 1, **attrs)
  end

  def add!(item, warehouse, **settings)
    expect(manager.add_many(warehouse_id: warehouse.id, items: [ { product_id: item.id, **settings } ])).to be_ok
    ProductWarehouseSetting.find_by!(product: item, warehouse: warehouse)
  end

  def stock!(item, warehouse, qty, direction: :in)
    InventoryMovement.create!(business: business, product: item, warehouse: warehouse, direction: direction,
                              quantity: qty, unit_cost: 1, reason: :adjustment, occurred_on: Date.current)
  end

  def report(warehouse_ids: nil) = described_class.new(business, warehouse_ids: warehouse_ids)

  it "compares legacy product-wide values with the central warehouse's row only" do
    matching = product("Matching", "M-1", low_stock_level: 5, reorder_quantity: 10)
    add!(matching, central, low_stock_level: 5, reorder_quantity: 10)
    differing = product("Differing", "D-1", low_stock_level: 5)
    add!(differing, central, low_stock_level: 2)
    branch_only = product("Branch only", "B-1", reorder_level: 3)
    add!(branch_only, branch_wh, low_stock_level: 9)
    product("Defaults", "Z-1") # no legacy values, but relies on the legacy stock-wide alert: listed (legacy_alert_only)

    rows = report.legacy.rows.to_h { |row| [ row.product.name, row.status ] }

    expect(report.central_target).to eq(central)
    expect(rows).to eq("Matching" => "matches", "Differing" => "differs", "Branch only" => "no_central_row", "Defaults" => "no_central_row")
    expect(report.legacy.rows.to_h { |row| [ row.product.name, row.transfer ] })
      .to include("Defaults" => "legacy_alert_only", "Matching" => "matching", "Differing" => "differing")
  end

  it "does not guess the historical central warehouse when there are several (or none)" do
    business.warehouses.create!(name: "Old Central", kind: "central")
    legacy = product("Legacy", "L-1", low_stock_level: 4)

    expect(report.central_target).to be_nil
    expect(report.central_candidates.map(&:name)).to contain_exactly("Main Warehouse", "Old Central")
    expect(report.legacy.rows.find { |r| r.product == legacy }.status).to eq("no_central_target")
  end

  it "lists explicit branch rows, stock without a row, and Inactive pairs with stock" do
    shampoo = product("Shampoo", "SH-1")
    mask    = product("Mask", "MK-1")
    branch_row = add!(shampoo, branch_wh)
    stock!(mask, branch_wh, 3)                       # sales branch: Included by default, not "not added"
    closed = business.warehouses.create!(name: "Closed store", kind: "central")
    stock!(mask, closed, 3)
    closed.update!(status: "inactive")               # not included by default: stock, no row
    inactive = add!(mask, central)
    stock!(mask, central, 2)
    manager.deactivate(setting_id: inactive.id, reason: "Gone")

    r = report
    expect(r.branch_rows.rows).to eq([ branch_row ])
    expect(r.stock_without_row.rows.map { |p| [ p.product, p.warehouse, p.on_hand ] }).to eq([ [ mask, closed, 3 ] ])
    expect(r.inactive_with_stock.rows.map { |p| [ p.product, p.warehouse, p.on_hand ] }).to eq([ [ mask, central, 2 ] ])

    by_wh = r.warehouse_rows.index_by { |row| row.warehouse }
    expect(by_wh[branch_wh]).to have_attributes(active_rows: 1, inactive_rows: 0, unconfigured_with_stock: 0, inactive_with_stock: 0)
    expect(by_wh[closed]).to have_attributes(unconfigured_with_stock: 1)
    expect(by_wh[central]).to have_attributes(active_rows: 0, inactive_rows: 1, unconfigured_with_stock: 0, inactive_with_stock: 1)
  end

  it "flags suspicious records" do
    untracked = product("Untracked", "U-1", track_inventory: false)
    row = ProductWarehouseSetting.create!(product: untracked, warehouse: central) # pre-existing row (no new ones now)
    row.update_columns(low_stock_level: 4) # legacy data path, bypassing the manager
    archived = product("Archived", "A-1")
    add!(archived, central)
    archived.update_column(:active, false)
    negative = product("Negative", "N-1")
    stock!(negative, central, 1, direction: :out)
    unclassified = business.warehouses.create!(name: "Legacy store")
    in_unclassified = product("Old", "O-1")
    add!(in_unclassified, unclassified)

    codes = report.issues.rows.map { |i| [ i.code, i.product.name ] }
    expect(codes).to include([ "untracked_with_settings", "Untracked" ], [ "active_row_for_archived_product", "Archived" ],
                             [ "negative_on_hand", "Negative" ], [ "row_in_unclassified_warehouse", "Old" ])
    expect(report.issue_counts["negative_on_hand"]).to eq(1)
    expect(report.unclassified_warehouses).to eq([ unclassified ])
  end

  it "covers only the viewer's warehouses and never another business" do
    shampoo = product("Shampoo", "SH-1")
    stock!(shampoo, central, 5)
    stock!(shampoo, branch_wh, 5)
    foreign_wh = other.warehouses.create!(name: "Foreign")
    foreign = other.products.create!(name: "Foreign", sku: "F-1", initial_cost_price: 1, average_cost_price: 1)
    InventoryMovement.create!(business: other, product: foreign, warehouse: foreign_wh, direction: :in, quantity: 1,
                              unit_cost: 1, reason: :adjustment, occurred_on: Date.current)

    closed = business.warehouses.create!(name: "Closed store", kind: "central")
    stock!(shampoo, closed, 2)
    closed.update!(status: "inactive")
    scoped = report(warehouse_ids: [ closed.id ])
    expect(scoped.warehouses).to eq([ closed ])
    expect(scoped.stock_without_row.rows.map(&:warehouse)).to eq([ closed ])
    expect(report.stock_without_row.rows.map(&:product)).not_to include(foreign)
  end

  it "writes nothing" do
    shampoo = product("Shampoo", "SH-1", low_stock_level: 3)
    stock!(shampoo, branch_wh, 2)
    add!(shampoo, central)

    writes = []
    callback = ->(*, payload) { writes << payload[:sql] if payload[:sql] =~ /\A\s*(INSERT|UPDATE|DELETE)/i }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      r = report
      r.warehouse_rows
      r.legacy
      r.branch_rows
      r.stock_without_row
      r.inactive_with_stock
      r.issues
    end
    expect(writes).to be_empty
  end
end
