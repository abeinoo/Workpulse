require "rails_helper"
require "csv"

RSpec.describe "Inventory movement report — pagination, export, reconciliation", type: :model do
  let(:business) { create(:business) }
  let(:user)     { create(:user, :super_admin, business: business) }
  let(:main)     { business.warehouses.create!(name: "Main") }
  let(:outlet)   { business.warehouses.create!(name: "Outlet") }
  let(:branch)   { business.branches.create!(name: "Nasr City", active: true) }
  let(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
  end
  let(:start_on) { Date.new(2026, 8, 1) }

  def receive(qty:, on:, wh: main, item: product)
    r = business.goods_receipts.build(warehouse: wh, received_on: on)
    r.items.build(product: item, quantity: qty, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call.tap { |res| expect(res.ok?).to be(true) }.receipt
  end

  def issue(qty:, on:, wh: main)
    i = business.stock_issues.build(warehouse: wh, branch: branch, issued_on: on)
    i.items.build(product: product, quantity: qty)
    approve_and_post_stock_issue(i).tap { |res| expect(res.ok?).to be(true) }.issue
  end

  def transfer(qty:, on:)
    t = business.stock_transfers.build(source_warehouse: main, destination_warehouse: outlet, transferred_on: on)
    t.items.build(product: product, quantity: qty)
    Inventory::StockTransferPoster.new(t).call.tap { |res| expect(res.ok?).to be(true) }.transfer
  end

  def adjust(diff:, on:, reason: "manual_correction")
    a = business.stock_adjustments.build(warehouse: main, adjusted_on: on, reason: reason)
    a.items.build(product: product, quantity_difference: diff, unit_cost: (10 if reason == "opening_balance"))
    Inventory::AdjustmentPoster.new(a).call.tap { |res| expect(res.ok?).to be(true) }.adjustment
  end

  def report(**filters) = Inventory::Reports::Movements.new(business, **filters)

  # 1 receipt of 100 then 30 issues of 1 on consecutive days → 31 movements,
  # balances 100, 99, 98 … 70.
  def seed_history!
    receive(qty: 100, on: start_on)
    30.times { |i| issue(qty: 1, on: start_on + i + 1) }
  end

  describe "pagination" do
    before { seed_history! }

    it "pages newest first with the requested page size and a total count" do
      r = report
      expect(r.total_count).to eq(31)
      expect(r.total_pages(25)).to eq(2)
      expect(r.page(1, 25).size).to eq(25)
      expect(r.page(2, 25).size).to eq(6)
      expect(r.page(1, 25).first.movement.occurred_on).to eq(start_on + 30)
    end

    it "keeps every running balance identical across pages (balances use the full history)" do
      all_balances = report.rows.map(&:balance_after)
      paged        = (1..report.total_pages(25)).flat_map { |p| report.page(p, 25).map(&:balance_after) }
      expect(paged).to eq(all_balances)
      expect(report.page(2, 25).last.balance_after).to eq(100)      # the opening receipt
      expect(report.page(1, 25).first.balance_after).to eq(product.stock_in(main))
    end

    it "falls back to the default page size for unsupported values and clamps the page number" do
      expect(Inventory::Reports::Movements.per_page_for("999")).to eq(50)
      expect(Inventory::Reports::Movements.per_page_for("100")).to eq(100)
      expect(report.page(99, 25).first.movement.occurred_on).to eq(start_on + 5)
    end

    it "applies filters before paging without changing historical balances" do
      r = report(from: start_on + 21) # last 10 issues: balances 79 … 70
      expect(r.total_count).to eq(10)
      expect(r.page(1, 25).map(&:balance_after)).to eq((70..79).to_a)

      by_type = report(reason: "goods_receipt")
      expect(by_type.total_count).to eq(1)
      expect(by_type.page(1, 25).sole.balance_after).to eq(100)
    end

    it "filters by document number" do
      number = business.stock_issues.order(:id).last.issue_number
      r = report(document_number: number.downcase)
      expect(r.total_count).to eq(1)
      expect(r.page(1, 25).sole.document_number).to eq(number)
    end
  end

  describe "query behaviour" do
    def count_queries(&block)
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached] }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      count
    end

    it "loads a page with a constant number of queries, independent of row count" do
      receive(qty: 100, on: start_on)
      3.times { |i| issue(qty: 1, on: start_on + i + 1) }
      small = count_queries { report.page(1, 50).each { |r| [ r.product.name, r.warehouse.name, r.document_number ] } }

      27.times { |i| issue(qty: 1, on: start_on + i + 5) }
      large = count_queries { report.page(1, 50).each { |r| [ r.product.name, r.warehouse.name, r.document_number ] } }
      expect(large).to eq(small)
    end

    it "only instantiates the requested page" do
      seed_history!
      loaded = 0
      counter = ->(*, payload) { loaded += payload[:record_count] if payload[:class_name] == "InventoryMovement" }
      ActiveSupport::Notifications.subscribed(counter, "instantiation.active_record") { report.page(1, 25).to_a }
      expect(loaded).to eq(25)
    end
  end

  describe "export" do
    before do
      seed_history!
      receive(qty: 5, on: start_on + 2, wh: outlet)
    end

    it "CSV contains the report columns and exactly the filtered rows with screen balances" do
      r = report(warehouse_ids: [ main.id ], from: start_on + 26)
      csv = CSV.parse(Inventory::Reports::MovementsExport.new(r, business: business).to_csv.delete_prefix("﻿"))
      header, *rows = csv
      expect(header.size).to eq(Inventory::Reports::MovementsExport::COLUMNS.size)
      expect(rows.size).to eq(r.total_count)
      expect(rows.map { |row| row[8].to_d }).to eq(r.rows.map(&:balance_after))
      expect(rows.map { |row| row[4] }.uniq).to eq([ "Main" ])
      expect(rows.first[12]).to eq(business.stock_issues.order(:id).last.issue_number)
    end

    it "XLSX is a valid workbook with the same rows" do
      r = report(reason: "goods_receipt")
      data = Inventory::Reports::MovementsExport.new(r, business: business).to_xlsx
      sheet = Roo::Excelx.new(StringIO.new(data)).sheet(0)
      expect(sheet.last_row).to eq(1 + r.total_count)
      expect(sheet.row(2)[7].to_d).to eq(r.rows.first.out_quantity)
    end

    it "streams in batches" do
      r = report
      expect { |b| r.each_row(batch_size: 7, &b) }.to yield_control.exactly(r.total_count).times
      expect(r.each_row(batch_size: 7).map { |row| row.movement.id }).to eq(r.rows.map { |row| row.movement.id })
    end
  end

  describe "current stock reconciliation" do
    it "stock = opening + receipts + transfer in + adjustments in − issues − transfer out − adjustments out ± reversals" do
      adjust(diff: 50, on: start_on, reason: "opening_balance")   # opening balance        +50
      receive(qty: 40, on: start_on + 1)                           # receipt                +40
      issue(qty: 12, on: start_on + 2)                             # issue                  −12
      transfer(qty: 8, on: start_on + 3)                           # transfer out (main)    −8
      adjust(diff: 3, on: start_on + 4)                            # adjustment in          +3
      adjust(diff: -5, on: start_on + 5)                           # adjustment out         −5
      voided = issue(qty: 6, on: start_on + 6)                     # issue                  −6
      Inventory::DocumentVoider.new(voided, user: user, reason: "mistake").call  # reversal +6

      signed = ->(rel) { rel.sum(Arel.sql("CASE WHEN direction = 'in' THEN quantity ELSE -quantity END")) }
      ledger = product.inventory_movements.where(warehouse: main)
      by = ->(reason) { signed.call(ledger.where(reason: reason)) }

      expected = by.call("opening_balance") + by.call("goods_receipt") + by.call("transfer_in") +
                 by.call("adjustment") + by.call("stock_issue") + by.call("transfer_out") + by.call("reversal")
      expect(expected).to eq(50 + 40 - 12 - 8 + 3 - 5 - 6 + 6)

      current = Inventory::Reports::CurrentStock.new(business, warehouse_ids: [ main.id ]).rows.find { |r| r.product == product }
      expect(current.on_hand).to eq(expected)
      expect(report(warehouse_ids: [ main.id ]).page(1, 50).first.balance_after).to eq(current.on_hand)
      expect(product.stock_in(outlet)).to eq(8)
    end
  end
end
