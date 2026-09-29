require "rails_helper"
require "csv"

# Branch comparison: consumption per (branch, supplying warehouse) from
# Inventory::ConsumptionLedger; stock per warehouse shown once, reconciled
# against StockLevels. Warehouse ↔ branch supply is derived from the ledger.
RSpec.describe Inventory::Reports::BranchComparison, type: :model do
  let(:business) { create(:business) }
  let(:user)     { create(:user, :super_admin, business: business) }
  let(:main)     { business.warehouses.create!(name: "Main") }     # shared: supplies Nasr + Shubra
  let(:outlet)   { business.warehouses.create!(name: "Outlet") }   # separate: supplies Zamalek only
  let(:nasr)     { business.branches.create!(name: "Nasr", active: true) }
  let(:shubra)   { business.branches.create!(name: "Shubra", active: true) }
  let(:zamalek)  { business.branches.create!(name: "Zamalek", active: true) }
  let(:quiet)    { business.branches.create!(name: "Quiet", active: true) } # supplied, but not this product
  let(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
  end
  let(:other_product) do
    business.products.create!(name: "Wax", sku: "WX-1", initial_cost_price: 4, average_cost_price: 4)
  end
  let(:from)  { Date.new(2026, 9, 1) }
  let(:to)    { Date.new(2026, 9, 10) } # 10 days
  let(:today) { to }

  def receive(qty:, wh: main, on: from, item: product)
    r = business.goods_receipts.build(warehouse: wh, received_on: on)
    r.items.build(product: item, quantity: qty, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call.tap { |res| expect(res.ok?).to be(true) }.receipt
  end

  def issue(qty:, branch:, wh: main, on: from + 1, item: product)
    i = business.stock_issues.build(warehouse: wh, branch: branch, issued_on: on)
    i.items.build(product: item, quantity: qty)
    approve_and_post_stock_issue(i).tap { |res| expect(res.ok?).to be(true) }.issue
  end

  def transfer(qty:, on: from + 2)
    t = business.stock_transfers.build(source_warehouse: main, destination_warehouse: outlet, transferred_on: on)
    t.items.build(product: product, quantity: qty)
    Inventory::StockTransferPoster.new(t).call.tap { |res| expect(res.ok?).to be(true) }.transfer
  end

  def adjust(diff:, wh: main, on: from + 3)
    a = business.stock_adjustments.build(warehouse: wh, adjusted_on: on, reason: "manual_correction")
    a.items.build(product: product, quantity_difference: diff)
    Inventory::AdjustmentPoster.new(a).call.tap { |res| expect(res.ok?).to be(true) }.adjustment
  end

  def void(doc, on:)
    travel_to(Time.zone.local(on.year, on.month, on.day, 12)) do
      Inventory::DocumentVoider.new(doc, user: user, reason: "mistake").call.tap { |res| expect(res.ok?).to be(true) }
    end
  end

  def report(**opts) = described_class.new(business, product_id: product.id, from: from, to: to, today: today, **opts)
  def branch_row(r, br) = r.branch_rows.find { |row| row.branch == br }
  def wh_row(r, wh)     = r.warehouse_rows.find { |row| row.warehouse == wh }

  before do
    receive(qty: 5, on: from - 10)                 # opening stock before the period (main)
    receive(qty: 100)                              # main +100
    receive(qty: 20, wh: outlet)                   # outlet +20
    receive(qty: 30, item: other_product)
    issue(qty: 30, branch: nasr)                   # main → Nasr
    issue(qty: 12, branch: shubra)                 # main → Shubra
    issue(qty: 6,  branch: zamalek, wh: outlet)    # outlet → Zamalek
    issue(qty: 2,  branch: quiet, item: other_product) # main supplies Quiet (other product only)
    transfer(qty: 15)                              # main −15 / outlet +15
    adjust(diff: 4)                                # main +4
    adjust(diff: -3)                               # main −3
  end

  describe "branch rows" do
    it "one row per branch with its supplying warehouse and branch-attributed consumption" do
      r = report
      expect(r.branch_rows.map { |row| [ row.branch.name, row.warehouse.name, row.net_consumption ] })
        .to eq([ [ "Nasr", "Main", 30 ], [ "Shubra", "Main", 12 ], [ "Zamalek", "Outlet", 6 ], [ "Quiet", "Main", 0 ] ])
      expect(r.total_consumption).to eq(48)
      expect(branch_row(r, nasr).share.round(2)).to eq(62.5)
      expect(branch_row(r, nasr).avg_daily_consumption).to eq(3)
    end

    it "marks branches that share a warehouse and does not give them branch-level coverage" do
      r = report
      expect(branch_row(r, nasr)).to be_shared
      expect(branch_row(r, shubra)).to be_shared
      expect(branch_row(r, nasr).warehouse_stock).to be_nil # shared stock is not repeated per branch
      expect(branch_row(r, nasr).coverage_days).to be_nil
      expect(r.total_stock).to eq(product.current_stock) # counted once, not per branch
    end

    it "gives a branch with its own warehouse a coverage of stock / daily consumption" do
      row = branch_row(report, zamalek)
      expect(row).not_to be_shared
      expect(row.warehouse_stock).to eq(29)         # 20 + 15 − 6
      expect(row.avg_daily_consumption).to eq(0.6)  # 6 / 10
      expect(row.coverage_days.round(2)).to eq(48.33)
    end

    it "lists a supplied branch with no consumption of this product as zero, excluded from highest/lowest" do
      r = report
      expect(branch_row(r, quiet).net_consumption).to eq(0)
      expect(branch_row(r, quiet)).not_to be_consuming
      expect(r.highest_branch.branch).to eq(nasr)
      expect(r.lowest_branch.branch).to eq(zamalek)
      expect(r.consuming_branch_count).to eq(3)
    end

    it "nets a voided issue on the original branch and never counts it twice" do
      voided = issue(qty: 7, branch: nasr, on: from + 4)
      void(voided, on: from + 5)
      row = branch_row(report, nasr)
      expect([ row.issued, row.reversed, row.net_consumption ]).to eq([ 37, 7, 30 ])
      expect(branch_row(report, shubra).reversed).to eq(0)
    end

    it "excludes draft / pending / approved / rejected / cancelled issues" do
      %w[draft pending_approval approved rejected cancelled].each do |status|
        i = business.stock_issues.build(warehouse: main, branch: nasr, issued_on: from + 1, status: status)
        i.items.build(product: product, quantity: 9)
        i.save!
      end
      expect(branch_row(report, nasr).net_consumption).to eq(30)
    end
  end

  describe "explicit supply links" do
    def link(branch, wh, active: true)
      Inventory::WarehouseSupplyAssigner.new(branch_id: branch.id, warehouse_id: wh.id, active: active, actor: user).call
    end

    it "one warehouse → multiple branches: stock is never repeated per branch (no 3× the units)" do
      [ nasr, shubra, quiet ].each { |b| link(b, main) }
      r = report
      rows = [ nasr, shubra, quiet ].map { |b| branch_row(r, b) }
      expect(rows.map(&:source).uniq).to eq([ :explicit ])
      expect(rows.map(&:shared?).uniq).to eq([ true ])
      expect(rows.map(&:warehouse_stock).uniq).to eq([ nil ])
      expect(rows.map(&:coverage_days).uniq).to eq([ nil ])
      expect(wh_row(r, main).branches).to contain_exactly(nasr, shubra, quiet)
      expect(r.total_stock).to eq(product.current_stock) # each warehouse counted once
    end

    it "one warehouse → one branch: stock and coverage = warehouse stock / branch daily consumption" do
      link(zamalek, outlet)
      row = branch_row(report, zamalek)
      expect([ row.source, row.exclusive? ]).to eq([ :explicit, true ])
      expect(row.warehouse_stock).to eq(product.stock_in(outlet))
      expect(row.coverage_days).to eq(product.stock_in(outlet) / (6 / 10r))
    end

    it "multiple warehouses → multiple branches" do
      link(nasr, main)
      link(shubra, outlet)
      link(zamalek, outlet)
      r = report
      # Main supplies Nasr (explicit) and Quiet (inferred, no explicit link) → shared.
      expect(branch_row(r, nasr)).to be_shared
      expect(wh_row(r, main).branches).to contain_exactly(nasr, quiet)
      expect(branch_row(r, shubra).warehouses).to eq([ outlet ])
      expect(branch_row(r, shubra)).to be_shared
      expect(wh_row(r, outlet).branches).to contain_exactly(shubra, zamalek)
    end

    it "explicit link takes priority over the inferred one; consumption still comes from the ledger" do
      link(shubra, outlet) # ledger shows Main supplied Shubra
      row = branch_row(report, shubra)
      expect([ row.warehouses, row.source ]).to eq([ [ outlet ], :explicit ])
      expect(row.net_consumption).to eq(12) # unchanged: the link never alters consumption
      expect(wh_row(report, main).branches).not_to include(shubra)
    end

    it "a branch without an explicit link falls back to the inferred warehouse" do
      link(nasr, main)
      row = branch_row(report, shubra)
      expect([ row.warehouses, row.source ]).to eq([ [ main ], :inferred ])
    end

    it "a warehouse-scoped view hides branches explicitly linked to other warehouses" do
      link(zamalek, main) # pinned to Main
      r = report(warehouse_ids: [ outlet.id ])
      expect(r.selectable_branches).not_to include(zamalek)
    end
  end

  describe "warehouse reconciliation" do
    it "opening + receipts + transfers in + adjustments in − consumption − transfers out − adjustments out ± reversals = closing = current stock" do
      voided = issue(qty: 7, branch: nasr, on: from + 4)
      void(voided, on: from + 5)
      r = report
      main_row = wh_row(r, main)
      expect(main_row.opening).to eq(5)
      expect([ main_row.receipts, main_row.transfers_in, main_row.transfers_out ]).to eq([ 100, 0, 15 ])
      expect([ main_row.adjustments_in, main_row.adjustments_out ]).to eq([ 4, 3 ])
      expect([ main_row.consumption, main_row.reversals ]).to eq([ 49, 7 ]) # 30 + 12 + 7 issued, 7 reversed
      expect(main_row.closing).to eq(5 + 100 + 0 + 4 - 49 - 15 - 3 + 7)
      expect(main_row.closing).to eq(product.stock_in(main))
      expect(main_row).to be_reconciles

      outlet_row = wh_row(r, outlet)
      expect(outlet_row.closing).to eq(product.stock_in(outlet))
      current = Inventory::Reports::CurrentStock.new(business).rows.find { |row| row.product == product }
      expect(r.warehouse_rows.sum(&:closing)).to eq(current.on_hand)
    end

    it "shows each warehouse once with the branches it supplies" do
      r = report
      expect(r.warehouse_rows.map(&:warehouse)).to eq([ main, outlet ])
      expect(wh_row(r, main).branches).to contain_exactly(nasr, shubra, quiet)
      expect(wh_row(r, main)).to be_shared
      expect(wh_row(r, outlet)).not_to be_shared
      expect(wh_row(r, main).coverage_days).to eq(product.stock_in(main) / 4.2) # (30 + 12) / 10 days
    end

    it "closing is the balance at the end of the period, not today's, for a past period" do
      issue(qty: 1, branch: nasr, on: to + 1)
      r = report
      expect(wh_row(r, main).closing).to eq(product.stock_in(main) + 1)
      expect(wh_row(r, main)).not_to be_reconciles
      expect(r.period_includes_today?).to be(true) # today == to in this spec
    end
  end

  describe "filters" do
    it "date range limits flows and consumption but not current stock" do
      r = report(from: from + 2, to: to)
      expect(branch_row(r, nasr).net_consumption).to eq(0)
      expect(wh_row(r, main).opening).to eq(5 + 100 - 30 - 12) # this product only, before from+2
      expect(wh_row(r, main).current_stock).to eq(product.stock_in(main))
    end

    it "warehouse filter keeps only that warehouse and the branches it supplies" do
      r = report(warehouse_ids: [ outlet.id ])
      expect(r.warehouse_rows.map(&:warehouse)).to eq([ outlet ])
      expect(r.branch_rows.map(&:branch)).to eq([ zamalek ])
      expect(r.selectable_branches).to eq([ zamalek ])
      expect(r.total_consumption).to eq(6)
    end

    it "branch filter keeps that branch only" do
      expect(report(branch_id: shubra.id).branch_rows.map(&:branch)).to eq([ shubra ])
    end
  end

  describe "drill-down" do
    it "uses the Stock Movement query for the branch: its issues and reversals with ledger balances" do
      voided = issue(qty: 7, branch: nasr, on: from + 4)
      void(voided, on: from + 5)
      drill = report.movements_for(nasr.id)
      rows = drill.page(1, 25)
      expect(rows.map(&:reason)).to eq(%w[reversal stock_issue stock_issue])
      expect(rows.map(&:warehouse).uniq).to eq([ main ])
      all_main = Inventory::Reports::Movements.new(business, product_id: product.id, warehouse_ids: [ main.id ]).rows
      rows.each do |row|
        same = all_main.find { |m| m.movement.id == row.movement.id }
        expect([ row.balance_before, row.balance_after ]).to eq([ same.balance_before, same.balance_after ])
      end
    end
  end

  describe "export" do
    it "CSV and XLSX contain the branch rows and warehouse rows as computed" do
      r = report
      export = Inventory::Reports::BranchComparisonExport.new(r)
      csv = CSV.parse(export.to_csv.delete_prefix("﻿"))
      expect(csv.first).to eq([ "Shampoo", "SH-1", from.iso8601, to.iso8601 ])
      branch_block = csv[3, r.branch_rows.size]
      expect(branch_block.map { |row| [ row[0], row[7].to_d ] }).to eq(r.branch_rows.map { |b| [ b.branch.name, b.net_consumption ] })

      book = Roo::Excelx.new(StringIO.new(export.to_xlsx))
      expect(book.sheets.size).to eq(2)
      expect(book.sheet(0).last_row).to eq(1 + r.branch_rows.size)
      expect(book.sheet(1).last_row).to eq(1 + r.warehouse_rows.size)
      expect(book.sheet(1).row(2)[10].to_d).to eq(r.warehouse_rows.first.closing)
    end
  end

  it "is not ready without a product" do
    r = described_class.new(business, product_id: nil)
    expect(r.ready?).to be(false)
    expect(r.branch_rows).to eq([])
  end
end
