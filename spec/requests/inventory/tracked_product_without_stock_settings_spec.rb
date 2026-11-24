require "rails_helper"

# "Track stock quantity" (products.track_inventory) and low-stock / reorder
# settings are independent. Chairs, equipment and other fixed assets stay
# TRACKED: they are counted in stocktaking and their quantity is corrected
# through the normal workflows. They simply need no low-stock threshold or
# reorder quantity — none is required, and being tracked alone never raises a
# low-stock alert or a reorder suggestion.
RSpec.describe "Tracked product without low-stock or reorder settings (chairs, equipment)", type: :request do
  let(:business)  { create(:business) }
  let!(:owner)    { create(:user, :owner, business: business) }
  let(:counter)   { user_with_stock_permissions(business, :view_inventory, :manage_stock_counts) }
  let(:approver)  { user_with_stock_permissions(business, :view_inventory, :post_stock_counts) }
  let!(:central)  { business.warehouses.create!(name: "Central WH", kind: "central") }
  let!(:branch_wh) { business.warehouses.create!(name: "Nasr City WH", kind: "branch", branch: create(:branch, business: business)) }
  # Stale values in the retired product columns must not turn it into an alert either.
  let!(:chair) do
    business.products.create!(name: "Office Chair", sku: "CHAIR-1", initial_cost_price: 300, average_cost_price: 300)
            .tap { |p| write_retired_product_stock_columns!(p, low_stock_level: 50, reorder_quantity: 20, reorder_level: 50) }
  end

  def receive!(warehouse, qty)
    receipt = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    receipt.items.build(product: chair, quantity: qty, unit_cost: 300)
    expect(Inventory::GoodsReceiptPoster.new(receipt).call).to be_ok
  end

  def on_hand(warehouse) = Inventory::StockLevels.new(chair).in_warehouse(warehouse).to_d
  def doc = Nokogiri::HTML(response.body)

  it "is tracked and needs no warehouse threshold or reorder setting" do
    expect(chair).to be_track_inventory
    expect(chair.product_warehouse_settings).to be_empty

    sign_in owner
    get edit_inventory_product_path(chair)
    hint = doc.css(".form-hint").map(&:text).find { |t| t.include?("chairs and equipment") }
    expect(hint).to include("they stay in stock counts", "optional and set per warehouse")
    expect(response.body).not_to include("Untick for items whose quantity you don't track (chairs")
    patch inventory_product_path(chair), params: { product: { name: "Office Chair", sku: "CHAIR-1", track_inventory: "1" } }
    expect(response).to redirect_to(inventory_product_path(chair))
    expect(chair.reload).to be_track_inventory
    expect(ProductWarehouseSetting.count).to eq(0) # saving never creates or requires one
  end

  it "appears in stocktaking in every warehouse that includes it — even with no stock and no settings" do
    receive!(central, 4)
    [ central, branch_wh ].each do |warehouse|
      result = Inventory::StockCountCreator.new(actor: counter, warehouse_id: warehouse.id, counted_on: Date.current).call
      expect(result).to be_ok
      expect(result.count.items.map(&:product)).to include(chair)
    end
  end

  it "is counted and corrected through the stock count workflow" do
    receive!(central, 4)
    count = record_stock_count!(business: business, warehouse: central, counter: counter, lines: [ [ chair, 3 ] ], complete: true)
    expect(approve_stock_count(count, approver)).to be_ok

    expect(on_hand(central)).to eq(3)
    adjustment = count.reload.stock_adjustments.sole
    expect(adjustment.items.map { |i| [ i.product, i.quantity_difference.to_d ] }).to eq([ [ chair, -1 ] ])
    expect(ProductWarehouseSetting.count).to eq(0)
  end

  it "can be adjusted manually (damage, correction) like any tracked product" do
    receive!(central, 4)
    damaged = business.stock_adjustments.build(warehouse: central, adjusted_on: Date.current, reason: "damaged", created_by: owner)
    damaged.items.build(product: chair, quantity_difference: -2)
    expect(Inventory::AdjustmentPoster.new(damaged).call).to be_ok
    expect(on_hand(central)).to eq(2)
  end

  it "never raises a low-stock alert or a reorder suggestion just because it is tracked — even at zero stock" do
    receive!(central, 1) # Central: 1 on hand; Nasr City: none at all

    expect(Inventory::LowStockQuery.new(business).alerts).to be_empty
    expect(Inventory::Reports::LowStock.new(business).rows).to be_empty
    expect(Inventory::Reports::Overview.new(business).low_stock_count).to eq(0)

    sign_in owner
    [ inventory_root_path, inventory_low_stock_report_path, new_inventory_purchase_request_path, root_path ].each do |path|
      get path
      expect(response).to have_http_status(:ok)
      expect(doc.css(".low-stock-check-row, [data-low-stock-row]").map { |n| n["data-product-id"] }).not_to include(chair.id.to_s)
    end

    get inventory_product_path(chair)
    expect(response.body).not_to include(I18n.t("inventory.products.low_stock_badge"))
  end

  it "added to a warehouse with the default settings (0 / 0) still raises no alert, and stays countable" do
    manager = Inventory::ProductAvailabilityManager.new(actor: owner)
    expect(manager.add_many(warehouse_id: central.id, items: [ { product_id: chair.id } ])).to be_ok
    expect(ProductWarehouseSetting.sole).to have_attributes(low_stock_level: 0, reorder_quantity: 0)

    expect(Inventory::LowStockQuery.new(business).alerts).to be_empty
    result = Inventory::StockCountCreator.new(actor: counter, warehouse_id: central.id, counted_on: Date.current).call
    expect(result.count.items.map(&:product)).to include(chair)
  end

  describe "every normal inventory workflow works with no (or zero) threshold and reorder quantity" do
    let(:branch_record) { branch_wh.branch }

    it "Goods Receipts post into a warehouse with no setting and into one with an Active 0 / 0 setting" do
      Inventory::ProductAvailabilityManager.new(actor: owner).add_many(warehouse_id: branch_wh.id, items: [ { product_id: chair.id } ])
      expect(ProductWarehouseSetting.sole).to have_attributes(warehouse_id: branch_wh.id, low_stock_level: 0, reorder_quantity: 0)

      receive!(central, 5)
      receive!(branch_wh, 2)
      expect([ on_hand(central), on_hand(branch_wh) ]).to eq([ 5, 2 ])
      expect(InventoryMovement.where(product: chair, reason: "goods_receipt").count).to eq(2)
    end

    it "Stock Issues and Stock Transfers move it like any tracked product" do
      receive!(central, 6)
      transfer = business.stock_transfers.build(source_warehouse: central, destination_warehouse: branch_wh, transferred_on: Date.current)
      transfer.items.build(product: chair, quantity: 4)
      expect(Inventory::StockTransferPoster.new(transfer).call).to be_ok

      issue = business.stock_issues.build(warehouse: branch_wh, branch: branch_record, issued_on: Date.current)
      issue.items.build(product: chair, quantity: 1)
      expect(approve_and_post_stock_issue(issue)).to be_ok

      expect([ on_hand(central), on_hand(branch_wh) ]).to eq([ 2, 3 ])
      expect(ProductWarehouseSetting.count).to eq(0)
    end

    it "is listed in the stock reports and offered by the tracked-product pickers" do
      receive!(central, 3)
      expect(Inventory::Reports::CurrentStock.new(business).rows.find { |r| r.product == chair }&.on_hand).to eq(3)
      expect(Inventory::Reports::Movements.new(business, product_id: chair.id).rows.map(&:product).uniq).to eq([ chair ])
      expect(Inventory::ProductPickerSearch.new(business.products, kind: "tracked").call("CHAIR")).to include(chair)

      sign_in owner
      get inventory_current_stock_report_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Office Chair")
    end

    it "follows warehouse permissions like any product: a user scoped to one warehouse sees only that stock" do
      receive!(central, 3)
      receive!(branch_wh, 7)
      scoped = user_with_stock_permissions(business, :view_inventory, :view_inventory_reports)
      scoped.assigned_warehouses << central

      expect(Inventory::Reports::CurrentStock.new(business, warehouse_ids: scoped.inventory_warehouse_ids)
               .rows.find { |r| r.product == chair }&.on_hand).to eq(3)
      sign_in scoped
      get inventory_current_stock_report_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Office Chair")
      expect(response.body).not_to include(branch_wh.name)
    end
  end
end
