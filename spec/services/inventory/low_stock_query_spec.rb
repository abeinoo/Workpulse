require "rails_helper"

RSpec.describe Inventory::LowStockQuery, type: :model do
  let(:business) { create(:business) }
  let(:main)     { business.warehouses.create!(name: "Main") }
  let(:branch)   { business.warehouses.create!(name: "Branch") }

  # low > 0 gives the product an Active setting in `wh` (thresholds are per warehouse only).
  def product(low: 0, reorder: 0, wh: main, sku: "P-#{SecureRandom.hex(3)}")
    business.products.create!(name: "P", sku: sku, initial_cost_price: 1, average_cost_price: 1).tap do |p|
      p.product_warehouse_settings.create!(warehouse: wh, low_stock_level: low, reorder_quantity: reorder) if low.positive?
    end
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

  describe "each warehouse uses its own threshold" do
    it "uses the warehouse-specific low_stock_level" do
      p = product
      p.product_warehouse_settings.create!(warehouse: main, low_stock_level: 10, reorder_quantity: 30)
      receive(p, qty: 8, wh: main)  # 8 <= 10 → low for this warehouse

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

  describe "no product-level fallback" do
    # Existing databases still hold stale values in the retired product columns.
    def stale!(p, low: 50, reorder: 99, total: 50, notify: true)
      write_retired_product_stock_columns!(p, low_stock_level: low, reorder_quantity: reorder, reorder_level: total,
                                              receive_low_stock_notification: notify)
    end

    it "never alerts a product without a warehouse setting, whatever its stale product values" do
      p = product
      stale!(p)
      receive(p, qty: 3, wh: main) # 3 ≤ the stale 50 — ignored
      empty = product
      stale!(empty, low: 0, reorder: 0, total: 0) # the old "out of stock" total alert — gone

      expect(alerts).to be_empty
    end

    it "a warehouse without its own setting inherits nothing from the product or from another warehouse" do
      p = product(low: 5, reorder: 7, wh: branch)
      stale!(p)
      receive(p, qty: 3, wh: main) # Main: no setting → no alert, even at 3

      expect(alerts.map { |a| [ a.warehouse_id, a.low_stock_level, a.reorder_quantity ] }).to eq([ [ branch.id, 5, 7 ] ])
    end

    it "suggests the warehouse's own reorder quantity, never the product's" do
      p = product(low: 5, reorder: 0)
      stale!(p, reorder: 99)
      expect(alerts.sole.reorder_quantity).to eq(0)
    end

    it "notification follows the warehouse setting only: the stale product flag neither hides nor mutes an alert" do
      muted = product(low: 5, reorder: 1)
      stale!(muted, notify: true)
      muted.product_warehouse_settings.sole.update!(receive_low_stock_notification: false)
      loud = product(low: 5, reorder: 1)
      stale!(loud, notify: false) # used to drop the product from every alert

      by_product = alerts.to_h { |a| [ a.product, a.notifiable? ] }
      expect(by_product).to eq(muted => false, loud => true)
    end

    it "every alert names its warehouse" do
      product(low: 5, wh: main)
      product(low: 5, wh: branch)
      expect(alerts.map(&:warehouse_id)).to contain_exactly(main.id, branch.id)
      expect(alerts.first).not_to respond_to(:total?)
    end
  end

  describe "archived product exclusion" do
    it "excludes an archived standalone product even when its stock is below minimum" do
      p = product(low: 5, reorder: 10)
      receive(p, qty: 2, wh: main)  # 2 <= 5, would alert if active
      p.update!(active: false, archived_at: Time.current)

      expect(alerts).to be_empty
    end

    it "surfaces an active product's alert while ignoring an archived one" do
      active_product   = product(low: 5, reorder: 10)
      archived_product = product(low: 5, reorder: 10)
      receive(active_product,   qty: 2, wh: main)  # below threshold
      receive(archived_product, qty: 1, wh: main)  # also below threshold, but archived
      archived_product.update!(active: false, archived_at: Time.current)

      alert_products = alerts.map(&:product)
      expect(alert_products).to include(active_product)
      expect(alert_products).not_to include(archived_product)
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
