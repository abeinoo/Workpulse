require "rails_helper"

RSpec.describe Inventory::LowStockQuery, type: :model do
  let(:business) { create(:business) }
  let(:main)     { business.warehouses.create!(name: "Main") }
  let(:branch)   { business.warehouses.create!(name: "Branch") }

  def product(low: 0, reorder: 0, sku: "P-#{SecureRandom.hex(3)}")
    business.products.create!(name: "P", sku: sku, initial_cost_price: 1,
                              average_cost_price: 1, low_stock_level: low,
                              reorder_level: low, reorder_quantity: reorder)
  end

  def receive(prod, qty:, wh:)
    r = business.goods_receipts.build(warehouse: wh, received_on: Date.current)
    r.items.build(product: prod, quantity: qty, unit_cost: 1)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  subject(:alerts) { described_class.new(business).alerts }

  describe "the core requirement: per-warehouse evaluation" do
    it "alerts a branch warehouse at zero stock even when another warehouse is full" do
      p = product
      p.product_warehouse_settings.create!(warehouse: main,   low_stock_level: 5, reorder_quantity: 20)
      p.product_warehouse_settings.create!(warehouse: branch, low_stock_level: 5, reorder_quantity: 20)
      receive(p, qty: 100, wh: main)        # main is well stocked; branch has nothing

      branch_alert = alerts.find { |a| a.warehouse_id == branch.id }
      expect(branch_alert).to be_present
      expect(branch_alert.on_hand).to eq(0)
      expect(branch_alert.reorder_quantity).to eq(20)

      expect(alerts.map(&:warehouse_id)).not_to include(main.id) # main is NOT low
    end
  end

  describe "per-warehouse thresholds override the product default" do
    it "uses the warehouse-specific low_stock_level" do
      p = product(low: 0)
      p.product_warehouse_settings.create!(warehouse: main, low_stock_level: 10, reorder_quantity: 30)
      receive(p, qty: 8, wh: main)  # 8 <= 10 → low for this warehouse, despite product default of 0

      alert = alerts.find { |a| a.warehouse_id == main.id }
      expect(alert).to be_present
      expect(alert.on_hand).to eq(8)
      expect(alert.low_stock_level).to eq(10)
    end

    it "does not alert a configured warehouse that is above its threshold" do
      p = product
      p.product_warehouse_settings.create!(warehouse: main, low_stock_level: 5, reorder_quantity: 10)
      receive(p, qty: 50, wh: main)
      expect(alerts).to be_empty
    end
  end

  describe "fallback for products with no per-warehouse settings" do
    it "evaluates total stock against the product-level default" do
      p = product(low: 5, reorder: 10)
      receive(p, qty: 3, wh: main)  # total 3 <= 5

      alert = alerts.find { |a| a.product == p }
      expect(alert).to be_present
      expect(alert).to be_total
      expect(alert.warehouse_id).to be_nil
      expect(alert.on_hand).to eq(3)
    end

    it "does not alert when total is above the default" do
      p = product(low: 5)
      receive(p, qty: 9, wh: main)
      expect(alerts).to be_empty
    end
  end

  describe "archived product exclusion" do
    it "excludes an archived standalone product even when its stock is below minimum" do
      p = product(low: 5, reorder: 10)
      receive(p, qty: 2, wh: main)  # 2 <= 5, would alert if active
      p.update!(active: false, archived_at: Time.current)

      expect(alerts).to be_empty
    end

    it "excludes an archived child product even when its stock is below minimum" do
      parent = business.products.create!(
        name: "Family", sku: "FAM-#{SecureRandom.hex(3)}",
        initial_cost_price: 0, average_cost_price: 0
      )
      child = product(low: 5, reorder: 10)
      child.update!(parent_product_id: parent.id)
      receive(child, qty: 2, wh: main)  # 2 <= 5, would alert if active
      child.update!(active: false, archived_at: Time.current)

      expect(alerts.map(&:product)).not_to include(child)
    end

    it "surfaces an active child alert while ignoring its archived sibling" do
      parent = business.products.create!(
        name: "Family", sku: "FAM-#{SecureRandom.hex(3)}",
        initial_cost_price: 0, average_cost_price: 0
      )
      active_child   = product(low: 5, reorder: 10)
      archived_child = product(low: 5, reorder: 10)
      active_child.update!(parent_product_id: parent.id)
      archived_child.update!(parent_product_id: parent.id)

      receive(active_child,   qty: 2, wh: main)  # below threshold
      receive(archived_child, qty: 1, wh: main)  # also below threshold, but archived
      archived_child.update!(active: false, archived_at: Time.current)

      alert_products = alerts.map(&:product)
      expect(alert_products).to include(active_child)
      expect(alert_products).not_to include(archived_child)
    end

    it "counts the dashboard alert total using only active products" do
      active_product   = product(low: 5, reorder: 10)
      archived_product = product(low: 5, reorder: 10)
      receive(active_product,   qty: 2, wh: main)
      receive(archived_product, qty: 1, wh: main)
      archived_product.update!(active: false, archived_at: Time.current)

      expect(alerts.size).to eq(1)
      expect(alerts.first.product).to eq(active_product)
    end

    it "excludes an archived product from per-warehouse alerts" do
      p = product
      p.product_warehouse_settings.create!(warehouse: main, low_stock_level: 5, reorder_quantity: 10)
      receive(p, qty: 2, wh: main)  # 2 <= 5, would alert if active
      p.update!(active: false, archived_at: Time.current)

      expect(alerts).to be_empty
    end
  end
end
