require "rails_helper"

# Default inclusion: a product is available in every active warehouse used for
# normal inventory (central, unclassified, sales branch) unless explicitly
# Excluded (an Inactive row). Inactive warehouses and non-sales branch
# warehouses are not included automatically. The threshold is the one
# low-stock control (0 = no detection); a legacy "alerts off" stays off.
RSpec.describe "Product availability — default inclusion in every active warehouse" do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:manager)  { Inventory::ProductAvailabilityManager.new(actor: owner) }

  def sales_warehouse(name)
    business.warehouses.create!(name: name, kind: "branch", branch: create(:branch, business: business, name: "#{name} branch"))
  end

  let!(:nasr)    { sales_warehouse("Nasr City") }
  let!(:central) { business.warehouses.create!(name: "Central WH", kind: "central") }
  let!(:product) { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 1, average_cost_price: 1) }

  def stock!(warehouse, qty, item: product)
    InventoryMovement.create!(business: business, product: item, warehouse: warehouse, direction: :in,
                              quantity: qty, unit_cost: 1, reason: :adjustment, occurred_on: Date.current)
  end

  describe Warehouse, "#availability_included_by_default?" do
    it "is true for active central and active sales branch warehouses only (not unclassified)" do
      laundry = sales_warehouse("Laundry")
      laundry.branch.update_column(:branch_type, "laundry")
      closed = sales_warehouse("Closed")
      closed.update!(status: "inactive")
      unclassified = business.warehouses.create!(name: "Old store")
      closed_central = business.warehouses.create!(name: "Closed central", kind: "central", status: "inactive")

      expect([ nasr, central, unclassified, laundry.reload, closed, closed_central ].map(&:availability_included_by_default?))
        .to eq([ true, true, false, false, false, false ])
    end
  end

  describe Inventory::ProductAvailabilityOverview do
    it "lists every reachable active warehouse as Included, grouped by type, without creating rows" do
      other_branch = sales_warehouse("Shubra")
      overview = described_class.new(product, user: owner)
      expect(overview.branch_pairs.map { |p| [ p.warehouse, p.state ] }).to eq([ [ nasr, "included" ], [ other_branch, "included" ] ])
      expect(overview.central_pairs.map { |p| [ p.warehouse, p.state ] }).to eq([ [ central, "included" ] ])
      expect(overview.other_pairs).to be_empty
      expect(ProductWarehouseSetting.count).to eq(0)
    end
  end

  describe "the manager" do
    it "save_settings creates the row on the first save in any included warehouse — central too — never for an inactive one" do
      expect(manager.save_settings(product_id: product.id, warehouse_id: nasr.id, low_stock_level: 3, reorder_quantity: 6)).to be_ok
      expect(manager.save_settings(product_id: product.id, warehouse_id: central.id, low_stock_level: 9, reorder_quantity: 0)).to be_ok
      rows = ProductWarehouseSetting.order(:warehouse_id).map { |r| [ r.warehouse_id, r.status, r.low_stock_level ] }
      expect(rows).to contain_exactly([ nasr.id, "active", 3 ], [ central.id, "active", 9 ]) # independent per warehouse

      closed = business.warehouses.create!(name: "Closed central", kind: "central", status: "inactive")
      result = manager.save_settings(product_id: product.id, warehouse_id: closed.id, low_stock_level: 3, reorder_quantity: 0)
      expect(result.error).to eq(:not_authorized).or eq(:not_included_by_default)
    end

    it "save_settings keeps a legacy 'alerts off' choice" do
      manager.save_settings(product_id: product.id, warehouse_id: nasr.id, low_stock_level: 3, reorder_quantity: 0)
      ProductWarehouseSetting.sole.update_column(:receive_low_stock_notification, false)
      manager.save_settings(product_id: product.id, warehouse_id: nasr.id, low_stock_level: 5, reorder_quantity: 0)
      expect(ProductWarehouseSetting.sole).to have_attributes(low_stock_level: 5, receive_low_stock_notification: false)
    end

    it "exclude works with no row in any included warehouse (central too), needs a reason, and refuses archived products" do
      expect(manager.exclude(product_id: product.id, warehouse_id: nasr.id, reason: "").error).to eq(:reason_required)
      expect(manager.exclude(product_id: product.id, warehouse_id: central.id, reason: "Not stocked centrally")).to be_ok
      expect(ProductWarehouseSetting.find_by!(warehouse: central)).to have_attributes(status: "inactive", status_reason: "Not stocked centrally")

      expect(manager.exclude(product_id: product.id, warehouse_id: nasr.id, reason: "Discontinued")).to be_ok
      expect(manager.save_settings(product_id: product.id, warehouse_id: nasr.id, low_stock_level: 1, reorder_quantity: 0).error).to eq(:inactive)

      archived = business.products.create!(name: "Old", sku: "OLD", initial_cost_price: 1, average_cost_price: 1, active: false)
      expect(manager.exclude(product_id: archived.id, warehouse_id: nasr.id, reason: "x").error).to eq(:invalid_product)
      expect(manager.save_settings(product_id: archived.id, warehouse_id: nasr.id, low_stock_level: 1, reorder_quantity: 0).error).to eq(:invalid_product)
    end

    it "keeps an existing Active central row's settings and never reactivates an existing Inactive one" do
      manager.add_many(warehouse_id: central.id, items: [ { product_id: product.id, low_stock_level: 40, reorder_quantity: 100 } ])
      row = ProductWarehouseSetting.sole
      expect(Inventory::ProductAvailabilityOverview.new(product, user: owner).central_pairs.sole.setting).to eq(row)

      manager.deactivate(setting_id: row.id, reason: "Historical")
      expect(manager.save_settings(product_id: product.id, warehouse_id: central.id, low_stock_level: 1, reorder_quantity: 0).error).to eq(:inactive)
      expect(row.reload).to have_attributes(status: "inactive", low_stock_level: 40, reorder_quantity: 100)
    end

    it "refuses a user without the permission or outside their warehouse scope" do
      viewer = user_with_stock_permissions(business, :view_inventory, :manage_products, name: "No availability")
      scoped = user_with_stock_permissions(business, :view_inventory, :manage_product_availability, name: "Scoped")
      scoped.assigned_warehouses << central
      [ viewer, scoped ].each do |actor|
        m = Inventory::ProductAvailabilityManager.new(actor: actor)
        expect(m.exclude(product_id: product.id, warehouse_id: nasr.id, reason: "x").error).to eq(:not_authorized)
        expect(m.save_settings(product_id: product.id, warehouse_id: nasr.id, low_stock_level: 1, reorder_quantity: 0).error).to eq(:not_authorized)
      end
      expect(ProductWarehouseSetting.count).to eq(0)
    end

    it "an exclusion blocks incoming stock into that branch (the existing guard)" do
      manager.exclude(product_id: product.id, warehouse_id: nasr.id, reason: "x")
      receipt = business.goods_receipts.build(warehouse: nasr, received_on: Date.current, funding_source_kind: "supplier_credit")
      receipt.items.build(product: product, quantity: 2, unit_cost: 1)
      expect(Inventory::GoodsReceiptPoster.new(receipt).call).not_to be_ok
      expect(Inventory::StockLevels.new(product).by_warehouse[nasr.id]).to be_nil
    end
  end

  describe Inventory::LowStockQuery do
    it "detects nothing for a threshold of 0, and nothing for an Excluded branch" do
      other = business.products.create!(name: "Mask", sku: "MK-1", initial_cost_price: 1, average_cost_price: 1)
      manager.save_settings(product_id: product.id, warehouse_id: nasr.id, low_stock_level: 0, reorder_quantity: 0)
      manager.save_settings(product_id: other.id, warehouse_id: nasr.id, low_stock_level: 5, reorder_quantity: 0)

      alerts = described_class.new(business).alerts
      # Threshold 0 at the branch: no alert (and no product-level total alert).
      expect(alerts.map { |a| [ a.product.name, a.warehouse_id ] }).to eq([ [ "Mask", nasr.id ] ])

      manager.exclude(product_id: other.id, warehouse_id: nasr.id, reason: "x")
      expect(described_class.new(business).alerts).to be_empty
    end

    it "keeps detection but marks a legacy 'alerts off' pair as not notifiable" do
      manager.save_settings(product_id: product.id, warehouse_id: nasr.id, low_stock_level: 5, reorder_quantity: 0)
      ProductWarehouseSetting.sole.update_column(:receive_low_stock_notification, false)
      alert = described_class.new(business).alerts.sole
      expect(alert).not_to be_notifiable
    end
  end

  describe Inventory::StockCountCreator do
    it "leaves out a product Excluded in that branch with no stock there, but always counts one with stock" do
      empty_excluded = business.products.create!(name: "Mask", sku: "MK-1", initial_cost_price: 1, average_cost_price: 1)
      stocked_excluded = business.products.create!(name: "Gel", sku: "GL-1", initial_cost_price: 1, average_cost_price: 1)
      stock!(nasr, 2, item: stocked_excluded)
      manager.exclude(product_id: empty_excluded.id, warehouse_id: nasr.id, reason: "x")
      manager.exclude(product_id: stocked_excluded.id, warehouse_id: nasr.id, reason: "x")

      result = described_class.new(actor: owner, warehouse_id: nasr.id, counted_on: Date.current).call
      expect(result).to be_ok
      expect(result.count.items.map { |i| i.product.name }).to contain_exactly("Shampoo", "Gel")
    end
  end
end
