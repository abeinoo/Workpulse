require "rails_helper"

RSpec.describe Inventory::Reports::Movements, type: :model do
  let(:business) { create(:business) }
  let(:user)     { create(:user, :super_admin, business: business) }
  let(:main)     { business.warehouses.create!(name: "Main") }
  let(:outlet)   { business.warehouses.create!(name: "Outlet") }
  let(:branch)   { business.branches.create!(name: "Nasr City", active: true) }
  let(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
  end
  let(:other_product) do
    business.products.create!(name: "Conditioner", sku: "CO-1", initial_cost_price: 5, average_cost_price: 5)
  end

  let(:d1) { Date.new(2026, 9, 1) }
  let(:d2) { Date.new(2026, 9, 10) }
  let(:d3) { Date.new(2026, 9, 20) }

  def receive(qty:, on: d1, wh: main, item: product)
    r = business.goods_receipts.build(warehouse: wh, received_on: on)
    r.items.build(product: item, quantity: qty, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call.tap { |res| expect(res.ok?).to be(true) }.receipt
  end

  def issue(qty:, on: d2, wh: main)
    i = business.stock_issues.build(warehouse: wh, branch: branch, issued_on: on)
    i.items.build(product: product, quantity: qty)
    Inventory::StockIssuePoster.new(i).call.tap { |res| expect(res.ok?).to be(true) }.issue
  end

  def transfer(qty:, on: d2)
    t = business.stock_transfers.build(source_warehouse: main, destination_warehouse: outlet, transferred_on: on)
    t.items.build(product: product, quantity: qty)
    Inventory::StockTransferPoster.new(t).call.tap { |res| expect(res.ok?).to be(true) }
  end

  def adjust(diff:, on: d2)
    a = business.stock_adjustments.build(warehouse: main, adjusted_on: on, reason: "damaged")
    a.items.build(product: product, quantity_difference: diff)
    Inventory::AdjustmentPoster.new(a).call.tap { |res| expect(res.ok?).to be(true) }
  end

  def report(**filters)
    described_class.new(business, **filters).rows
  end

  # Newest row per (product, warehouse) — the report shows newest first.
  def latest_balance(rows, prod, wh)
    rows.find { |r| r.product == prod && r.warehouse == wh }&.balance_after
  end

  describe "movement types" do
    it "a goods receipt increases the balance" do
      receive(qty: 10)
      row = report.first
      expect([ row.reason, row.signed_quantity, row.balance_after ]).to eq([ "goods_receipt", 10, 10 ])
    end

    it "a stock issue decreases the balance" do
      receive(qty: 10)
      issue(qty: 3)
      row = report.first
      expect([ row.reason, row.signed_quantity, row.balance_after ]).to eq([ "stock_issue", -3, 7 ])
    end

    it "a transfer decreases the source and increases the destination" do
      receive(qty: 10)
      transfer(qty: 4)
      rows = report
      expect(latest_balance(rows, product, main)).to eq(6)
      expect(latest_balance(rows, product, outlet)).to eq(4)
    end

    it "an adjustment changes the balance" do
      receive(qty: 10)
      adjust(diff: -2)
      row = report.first
      expect([ row.reason, row.signed_quantity, row.balance_after ]).to eq([ "adjustment", -2, 8 ])
    end

    it "an approved stock count posts its variance and lands the balance on the counted quantity" do
      receive(qty: 10, on: Date.current)
      counter = create(:user, :super_admin, business: business)
      count = business.stock_counts.build(warehouse: main, counted_on: Date.current, created_by: counter)
      count.items.build(product: product, counted_quantity: 7)
      count.save!
      count.start_counting!(counter)
      count.mark_completed!(counter)
      expect(Inventory::StockCountApprover.new(count, user: user).call.ok?).to be(true)

      row = report.first
      expect([ row.reason, row.signed_quantity, row.balance_after ]).to eq([ "adjustment", -3, 7 ])
      expect(row.balance_after).to eq(product.stock_in(main))
    end

    it "an unapproved stock count does not move stock" do
      receive(qty: 10)
      count = business.stock_counts.build(warehouse: main, counted_on: d2, created_by: user)
      count.items.build(product: product, counted_quantity: 1)
      count.save!
      expect(report.size).to eq(1)
    end

    it "a voided document shows the original and its reversal, netting out" do
      receive(qty: 10)
      voided = issue(qty: 3)
      Inventory::DocumentVoider.new(voided, user: user, reason: "correction").call
      rows = report
      expect(rows.map(&:reason)).to include("stock_issue", "reversal")
      expect(latest_balance(rows, product, main)).to eq(10)
    end
  end

  describe "non-posted documents" do
    before { receive(qty: 10) }

    it "ignores draft goods receipts and draft / rejected / cancelled stock issues" do
      draft_receipt = business.goods_receipts.build(warehouse: main, received_on: d2)
      draft_receipt.items.build(product: product, quantity: 99, unit_cost: 10)
      draft_receipt.save!

      %w[draft pending_approval approved rejected cancelled].each do |status|
        i = business.stock_issues.build(warehouse: main, branch: branch, issued_on: d2, status: status)
        i.items.build(product: product, quantity: 5)
        i.save!
      end

      rows = report
      expect(rows.size).to eq(1)
      expect(rows.first.balance_after).to eq(10)
    end
  end

  describe "freshness and ordering" do
    it "shows a newly posted movement immediately, at the top" do
      receive(qty: 10)
      expect(report.size).to eq(1)

      posted = issue(qty: 4, on: d3)
      top = report.first
      expect(top.movement.source).to eq(posted)
      expect(top.balance_after).to eq(6)
    end

    it "lists newest first across products, not grouped by product" do
      receive(qty: 10, on: d1, item: product)
      receive(qty: 5,  on: d3, item: other_product)
      expect(report.map(&:product)).to eq([ other_product, product ])
    end

    it "breaks same-day ties by posting order (id), deterministically" do
      receive(qty: 10, on: d2)
      issue(qty: 1, on: d2)
      issue(qty: 2, on: d2)
      rows = report
      expect(rows.map { |r| r.movement.id }).to eq(rows.map { |r| r.movement.id }.sort.reverse)
      expect(rows.map(&:balance_after)).to eq([ 7, 9, 10 ])
    end

    it "places a back-dated posting at its movement date, recomputing later balances" do
      receive(qty: 10, on: d1)
      issue(qty: 3, on: d3)
      receive(qty: 5, on: d2) # posted last, dated in between
      expect(report.map(&:balance_after)).to eq([ 12, 15, 10 ])
    end
  end

  describe "running balance reconciles with actual stock" do
    before do
      receive(qty: 20, on: d1)
      issue(qty: 3, on: d2)
      transfer(qty: 5, on: d2)
      adjust(diff: -1, on: d3)
      receive(qty: 2, on: d1, wh: outlet)
    end

    it "the newest balance per warehouse equals Product#stock_in" do
      rows = report
      [ main, outlet ].each do |wh|
        expect(latest_balance(rows, product, wh)).to eq(product.stock_in(wh))
      end
    end

    it "every balance is the chronological sum of signed quantities" do
      chronological = report.reverse
      chronological.group_by { |r| [ r.product.id, r.warehouse.id ] }.each_value do |group|
        expect(group.map(&:balance_after)).to eq(group.map(&:signed_quantity).each_with_object([]) { |q, acc| acc << (acc.last.to_d + q) })
      end
    end
  end

  describe "filters" do
    before do
      receive(qty: 20, on: d1)                       # main: 20
      issue(qty: 3, on: d2)                          # main: 17
      receive(qty: 6, on: d2, wh: outlet)            # outlet: 6
      receive(qty: 4, on: d2, item: other_product)   # other @ main: 4
      issue(qty: 2, on: d3)                          # main: 15
    end

    it "date range: limits rows to the window and continues from the opening balance" do
      rows = report(from: d2, to: d2)
      expect(rows.map { |r| r.movement.occurred_on }.uniq).to eq([ d2 ])
      expect(latest_balance(rows, product, main)).to eq(17)   # 20 opening - 3, not -3
      expect(latest_balance(rows, product, outlet)).to eq(6)
    end

    it "date range: accepts ISO strings from params and ignores invalid ones" do
      expect(report(from: d3.iso8601).map(&:balance_after)).to eq([ 15 ])
      expect(report(from: "not-a-date").size).to eq(5)
    end

    it "from only: the newest balance still equals current stock" do
      rows = report(from: d3)
      expect(rows.size).to eq(1)
      expect(rows.first.balance_after).to eq(product.stock_in(main))
    end

    it "warehouse filter: only that warehouse's movements and balances" do
      rows = report(warehouse_ids: [ outlet.id ])
      expect(rows.map(&:warehouse).uniq).to eq([ outlet ])
      expect(rows.first.balance_after).to eq(6)
    end

    it "warehouse + date filter: opening balance comes from that warehouse only" do
      rows = report(warehouse_ids: [ main.id ], product_id: product.id, from: d3)
      expect(rows.map(&:balance_after)).to eq([ 15 ])
    end

    it "product filter: only that product's movements" do
      rows = report(product_id: other_product.id)
      expect(rows.map(&:product).uniq).to eq([ other_product ])
      expect(rows.first.balance_after).to eq(4)
    end
  end
end
