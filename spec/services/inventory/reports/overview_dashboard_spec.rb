require "rails_helper"

RSpec.describe "Inventory overview dashboard services", type: :model do
  let(:business) { create(:business) }
  let(:user)     { create(:user, :super_admin, business: business) }
  let(:main)     { business.warehouses.create!(name: "Main") }
  let(:outlet)   { business.warehouses.create!(name: "Outlet") }
  let(:nasr)     { business.branches.create!(name: "Nasr", active: true) }
  let(:shubra)   { business.branches.create!(name: "Shubra", active: true) }
  let(:shampoo)  { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10, reorder_level: 5, reorder_quantity: 20) }
  let(:wax)      { business.products.create!(name: "Wax", sku: "WX-1", initial_cost_price: 4, average_cost_price: 4) }
  let(:today)    { BusinessDay.current(context: business) }

  def receive(product, qty, wh: main, on: today)
    r = business.goods_receipts.build(warehouse: wh, received_on: on)
    r.items.build(product: product, quantity: qty, unit_cost: product.average_cost_price)
    Inventory::GoodsReceiptPoster.new(r).call.tap { |res| expect(res.ok?).to be(true) }.receipt
  end

  def issue(product, qty, branch:, wh: main, on: today)
    i = business.stock_issues.build(warehouse: wh, branch: branch, issued_on: on)
    i.items.build(product: product, quantity: qty)
    Inventory::StockIssuePoster.new(i).call.tap { |res| expect(res.ok?).to be(true) }.issue
  end

  def transfer(product, qty, on: today)
    t = business.stock_transfers.build(source_warehouse: main, destination_warehouse: outlet, transferred_on: on)
    t.items.build(product: product, quantity: qty)
    Inventory::StockTransferPoster.new(t).call.tap { |res| expect(res.ok?).to be(true) }.transfer
  end

  def adjust(product, diff, on: today)
    a = business.stock_adjustments.build(warehouse: main, adjusted_on: on, reason: "damaged")
    a.items.build(product: product, quantity_difference: diff)
    Inventory::AdjustmentPoster.new(a).call.tap { |res| expect(res.ok?).to be(true) }.adjustment
  end

  def void(doc) = Inventory::DocumentVoider.new(doc, user: user, reason: "mistake").call.tap { |r| expect(r.ok?).to be(true) }

  def period(key = "30d", **opts) = Inventory::Reports::Period.new(business, key: key, **opts)

  describe Inventory::Reports::Period do
    it "resolves today / 7d / 30d / month / custom from the business day" do
      expect(period("today").range).to eq(today..today)
      expect(period("7d").range).to eq((today - 6)..today)
      expect(period("30d").days).to eq(30)
      expect(period("month").from).to eq(today.beginning_of_month)
      expect(period("custom", from: (today - 3).iso8601, to: today.iso8601).days).to eq(4)
      expect(period("bogus").key).to eq("30d")
      reversed = period("custom", from: today.iso8601, to: (today - 2).iso8601)
      expect(reversed).to be_invalid
      expect(reversed.range).to eq((today - 29)..today) # falls back to the default, never guesses
    end
  end

  describe "Period presets at a month end" do
    it "resolves last month / 3m / 6m / year / default from the business day" do
      travel_to(Time.zone.local(2026, 3, 31, 12)) do
        t = BusinessDay.current(context: business)
        p = ->(key) { Inventory::Reports::Period.new(business, key: key, default: "month").range }
        expect(p.("last_month")).to eq(t.prev_month.beginning_of_month..t.prev_month.end_of_month)
        expect(p.("3m")).to eq((t.months_ago(3) + 1)..t)
        expect(p.("6m")).to eq((t.months_ago(6) + 1)..t)
        expect(p.("year")).to eq(t.beginning_of_year..t)
        expect(p.(nil)).to eq(t.beginning_of_month..t)
        expect(Inventory::Reports::Period.new(business, key: "year", keys: %w[month]).key).to eq("30d") # not offered → default
      end
    end
  end

  describe Inventory::Reports::MovementSummary do
    before do
      receive(shampoo, 50)                       # receipts +50 (500)
      receive(wax, 10)                           # receipts +10 (40)
      issue(shampoo, 8, branch: nasr)            # issues 8 (80)
      voided = issue(shampoo, 3, branch: nasr)   # issue 3 … then voided
      void(voided)
      transfer(shampoo, 5)                       # out main / in outlet (50 each)
      adjust(shampoo, -2)                        # adjustments −2 (−20)
      receive(shampoo, 99, on: today - 40)       # outside the 30-day window
    end

    let(:summary) { Inventory::Reports::MovementSummary.new(business, period: period) }

    it "aggregates each flow, folding a voided issue back into issues" do
      t = summary.totals
      expect([ t[:receipts].quantity, t[:receipts].value ]).to eq([ 60, 540 ])
      expect([ t[:issues].quantity, t[:issues].value ]).to eq([ 8, 80 ])
      expect([ t[:transfers_in].quantity, t[:transfers_out].quantity ]).to eq([ 5, 5 ])
      expect(t[:adjustments].quantity).to eq(-2)
    end

    it "issues equal the ConsumptionLedger net for the same period" do
      ledger = Inventory::ConsumptionLedger.new(business, reasons: Inventory::ConsumptionLedger::ALL_CONSUMPTION,
                                                          from: period.from, to: period.to)
      expect(summary.totals[:issues].quantity).to eq(ledger.net_quantity)
      expect(summary.totals[:issues].value).to eq(ledger.net_cost)
    end

    it "net movement equals the ledger's signed sum for the period" do
      signed = InventoryMovement.where(business: business, occurred_on: period.range)
                                .sum(Arel.sql(Inventory::StockLevels::SIGNED))
      expect(summary.net.quantity).to eq(signed)
      expect(summary.net.quantity).to eq(60 - 8 + 5 - 5 - 2)
    end

    it "honours the date range and the warehouse scope" do
      expect(Inventory::Reports::MovementSummary.new(business, period: period("custom", from: (today - 45).iso8601, to: (today - 35).iso8601))
                                                .totals[:receipts].quantity).to eq(99)
      scoped = Inventory::Reports::MovementSummary.new(business, period: period, warehouse_ids: [ outlet.id ])
      expect(scoped.totals[:transfers_in].quantity).to eq(5)
      expect(scoped.totals[:receipts].quantity).to eq(0)
    end

    it "gives a zero-filled daily trend of receipts and issues value" do
      trend = summary.daily_trend
      expect(trend.size).to eq(30)
      expect(trend.last).to eq([ today, 540, 80 ])
      expect(trend.first).to eq([ today - 29, 0, 0 ])
    end

    it "counts movements per warehouse" do
      expect(summary.counts_by_warehouse[outlet.id]).to eq(1)
    end
  end

  describe Inventory::Reports::ActiveProducts do
    before do
      receive(shampoo, 100)
      receive(wax, 100)
      issue(shampoo, 5, branch: nasr)
      issue(shampoo, 7, branch: shubra)
      issue(shampoo, 1, branch: nasr)
      issue(wax, 2, branch: nasr)
      void(issue(wax, 9, branch: shubra))
      issue(shampoo, 50, branch: nasr, on: today - 60) # outside the period
    end

    it "ranks products by net issued quantity, with issue count and top branch (voids excluded)" do
      rows = Inventory::Reports::ActiveProducts.new(business, period: period).rows
      expect(rows.map { |r| [ r.product, r.quantity, r.issue_count, r.top_branch, r.top_branch_quantity ] })
        .to eq([ [ shampoo, 13, 3, shubra, 7 ], [ wax, 2, 1, nasr, 2 ] ])
    end

    it "changes with the period" do
      rows = Inventory::Reports::ActiveProducts.new(business, period: period("custom", from: (today - 90).iso8601, to: today.iso8601)).rows
      expect(rows.first.quantity).to eq(63)
      expect(rows.first.top_branch).to eq(nasr)
    end
  end

  describe Inventory::Reports::WarehouseSummary do
    it "per warehouse: value, in-stock, out-of-stock, low-stock and movements — adding up to Current Stock" do
      receive(shampoo, 10)
      receive(wax, 3, wh: outlet)
      transfer(shampoo, 10) # main now 0 shampoo → out of stock there
      shampoo.product_warehouse_settings.create!(warehouse: outlet, low_stock_level: 20, reorder_quantity: 5)

      alerts = Inventory::LowStockQuery.new(business).alerts
      movements = Inventory::Reports::MovementSummary.new(business, period: period)
      summary = Inventory::Reports::WarehouseSummary.new(business, warehouses: [ main, outlet ], movement_summary: movements,
                                                                   low_stock_alerts: alerts)
      main_row, outlet_row = summary.rows
      expect([ main_row.stock_value, main_row.products_in_stock, main_row.out_of_stock ]).to eq([ 0, 0, 1 ])
      expect([ outlet_row.stock_value, outlet_row.products_in_stock, outlet_row.low_stock ]).to eq([ 112, 2, 1 ])
      expect(main_row.movements).to eq(2)
      expect(summary.total_value).to eq(Inventory::Reports::CurrentStock.new(business).total_value)
    end
  end
end
