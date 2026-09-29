require "rails_helper"

# Inventory Reports dashboard services. Every quantity must agree with the
# ledger (Product#stock_in / StockLevels) and only posted documents count.
RSpec.describe "Inventory::Reports dashboard services", type: :model do
  let(:business) { create(:business) }
  let(:user)     { create(:user, :super_admin, business: business) }
  let(:main)     { business.warehouses.create!(name: "Main") }
  let(:outlet)   { business.warehouses.create!(name: "Outlet") }
  let(:branch)   { business.branches.create!(name: "Nasr City", active: true) }
  let(:supplier) { business.suppliers.create!(name: "Acme") }
  let(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10,
                              reorder_level: 5, reorder_quantity: 12)
  end
  let(:idle) do
    business.products.create!(name: "Idle Wax", sku: "IW-1", initial_cost_price: 4, average_cost_price: 4)
  end
  let(:today) { BusinessDay.current(context: business) }

  def receive(qty:, item: product, wh: main, on: today, cost: 10, with_supplier: true)
    r = business.goods_receipts.build(warehouse: wh, received_on: on, supplier: (supplier if with_supplier))
    r.items.build(product: item, quantity: qty, unit_cost: cost)
    Inventory::GoodsReceiptPoster.new(r).call.tap { |res| expect(res.ok?).to be(true) }.receipt
  end

  def issue(qty:, on: today, wh: main)
    i = business.stock_issues.build(warehouse: wh, branch: branch, issued_on: on)
    i.items.build(product: product, quantity: qty)
    approve_and_post_stock_issue(i).tap { |res| expect(res.ok?).to be(true) }.issue
  end

  def transfer(qty:, on: today)
    t = business.stock_transfers.build(source_warehouse: main, destination_warehouse: outlet, transferred_on: on)
    t.items.build(product: product, quantity: qty)
    Inventory::StockTransferPoster.new(t).call.tap { |res| expect(res.ok?).to be(true) }.transfer
  end

  def adjust(diff:, reason: "damaged", on: today, user_id: user.id)
    a = business.stock_adjustments.build(warehouse: main, adjusted_on: on, reason: reason, created_by_id: user_id)
    a.items.build(product: product, quantity_difference: diff)
    Inventory::AdjustmentPoster.new(a).call.tap { |res| expect(res.ok?).to be(true) }.adjustment
  end

  def void(doc)
    Inventory::DocumentVoider.new(doc, user: user, reason: "correction").call.tap { |res| expect(res.ok?).to be(true) }
  end

  # Unposted documents of every kind that must never affect a report.
  def create_unposted_documents!
    draft = business.goods_receipts.build(warehouse: main, received_on: today, supplier: supplier)
    draft.items.build(product: product, quantity: 500, unit_cost: 10)
    draft.save!

    rejected = business.goods_receipts.build(warehouse: main, received_on: today, supplier: supplier,
                                             approval_status: "rejected")
    rejected.items.build(product: product, quantity: 300, unit_cost: 10)
    rejected.save!

    %w[draft pending_approval approved rejected cancelled].each do |status|
      i = business.stock_issues.build(warehouse: main, branch: branch, issued_on: today, status: status)
      i.items.build(product: product, quantity: 4)
      i.save!
    end
  end

  describe Inventory::Reports::CurrentStock do
    before do
      receive(qty: 20)
      issue(qty: 5)
      receive(qty: 3, wh: outlet)
      idle # tracked product that never moved → out of stock
      create_unposted_documents!
    end

    it "reports on-hand equal to the ledger, ignoring unposted documents" do
      row = described_class.new(business).rows.find { |r| r.product == product }
      expect(row.on_hand).to eq(18)
      expect(row.on_hand).to eq(product.current_stock)
      expect(row.stock_value).to eq(180)
    end

    it "is warehouse-scoped" do
      row = described_class.new(business, warehouse_ids: [ outlet.id ]).rows.find { |r| r.product == product }
      expect(row.on_hand).to eq(product.stock_in(outlet))
    end

    it "filters out-of-stock products" do
      report = described_class.new(business, stock_status: "out_of_stock")
      expect(report.rows.map(&:product)).to eq([ idle ])
      expect(report.out_of_stock_count).to eq(1)
    end

    it "excludes untracked products" do
      product.update!(track_inventory: false)
      expect(described_class.new(business).rows.map(&:product)).not_to include(product)
    end
  end

  describe Inventory::Reports::LowStock do
    it "lists products at or below the reorder level with the configured reorder quantity as the suggestion" do
      receive(qty: 4)
      row = described_class.new(business).rows.find { |r| r.product == product }
      expect(row.on_hand).to eq(4)
      expect(row.low_stock_level).to eq(5)
      expect(row.suggested_quantity).to eq(12)
      expect(row.suggested_value).to eq(120)
    end

    it "uses the per-warehouse setting when one exists" do
      receive(qty: 50)
      product.product_warehouse_settings.create!(warehouse: main, low_stock_level: 60, reorder_quantity: 30)
      row = described_class.new(business).rows.find { |r| r.product == product }
      expect([ row.warehouse_id, row.on_hand, row.suggested_quantity ]).to eq([ main.id, 50, 30 ])
    end

    it "drops a product once posted stock lifts it above the level" do
      receive(qty: 4)
      receive(qty: 10)
      expect(described_class.new(business).rows.map(&:product)).not_to include(product)
    end
  end

  describe Inventory::Reports::NoMovement do
    it "lists products idle longer than the window, and never-moved products" do
      receive(qty: 5, item: idle, on: today - 120)
      receive(qty: 5, on: today - 10)
      rows = described_class.new(business, days: 90, today: today).rows
      expect(rows.map(&:product)).to eq([ idle ])
      expect(rows.first.days_idle).to eq(120)
      expect(rows.first.on_hand).to eq(idle.current_stock)
    end
  end

  describe Inventory::Reports::Consumption do
    it "sums posted stock-issue consumption per product and branch" do
      receive(qty: 20)
      issue(qty: 3)
      issue(qty: 2)
      create_unposted_documents!
      row = described_class.new(business).rows.sole
      expect([ row.product, row.branch, row.net_quantity, row.net_value ]).to eq([ product, branch, 5, 50 ])
    end

    it "nets out a voided issue, attributed to the issue's branch" do
      receive(qty: 20)
      issue(qty: 3)
      void(issue(qty: 2))
      row = described_class.new(business).rows.sole
      expect([ row.branch, row.issued_quantity, row.reversed_quantity, row.net_quantity ]).to eq([ branch, 5, 2, 3 ])
    end

    it "honours the date range and branch filter" do
      receive(qty: 20, on: today - 30)
      issue(qty: 3, on: today - 20)
      issue(qty: 2, on: today)
      expect(described_class.new(business, from: today - 1).total_quantity).to eq(2)
      other = business.branches.create!(name: "Other", active: true)
      expect(described_class.new(business, branch_id: other.id).rows).to be_empty
    end
  end

  describe Inventory::Reports::Transfers do
    before { receive(qty: 20) }

    it "lists posted transfer lines; the ledger reflects them on both ends" do
      transfer(qty: 4)
      row = described_class.new(business).rows.sole
      expect([ row.product, row.quantity, row.transfer.source_warehouse, row.transfer.destination_warehouse ])
        .to eq([ product, 4, main, outlet ])
      expect(product.stock_in(main)).to eq(16)
      expect(product.stock_in(outlet)).to eq(4)
    end

    it "excludes voided transfers by default and shows them on request" do
      void(transfer(qty: 4))
      expect(described_class.new(business).rows).to be_empty
      voided = described_class.new(business, status: "voided").rows
      expect(voided.size).to eq(1)
      expect(voided.first).to be_voided
      expect(described_class.new(business, status: "all").total_quantity).to eq(0)
    end

    it "shows a warehouse-scoped user transfers touching either end" do
      transfer(qty: 4)
      expect(described_class.new(business, warehouse_ids: [ outlet.id ]).rows.size).to eq(1)
      other = business.warehouses.create!(name: "Other")
      expect(described_class.new(business, warehouse_ids: [ other.id ]).rows).to be_empty
    end
  end

  describe Inventory::Reports::Adjustments do
    it "shows previous / adjustment / new quantity from the ledger, with reason, user and number" do
      receive(qty: 20)
      issue(qty: 5)
      adjustment = adjust(diff: -3)
      row = described_class.new(business).rows.sole
      expect([ row.balance_before, row.signed_quantity, row.balance_after ]).to eq([ 15, -3, 12 ])
      expect(row.balance_after).to eq(product.stock_in(main))
      expect([ row.adjustment, row.adjustment.reason, row.adjustment.created_by ]).to eq([ adjustment, "damaged", user ])
    end

    it "includes approved stock counts and filters by reason" do
      receive(qty: 10)
      adjust(diff: 2, reason: "manual_correction")
      counter = create(:user, :super_admin, business: business)
      count = business.stock_counts.build(warehouse: main, counted_on: today, created_by: counter)
      count.items.build(product: product, counted_quantity: 9)
      count.save!
      count.start_counting!(counter)
      count.mark_completed!(counter)
      expect(Inventory::StockCountApprover.new(count, user: user).call.ok?).to be(true)

      stock_count_rows = described_class.new(business, reason: "stock_count").rows
      expect(stock_count_rows.map { |r| [ r.balance_before, r.signed_quantity, r.balance_after ] }).to eq([ [ 12, -3, 9 ] ])
      expect(described_class.new(business).rows.size).to eq(2)
    end

    it "keeps a voided adjustment and its reversal in the trail" do
      receive(qty: 10)
      void(adjust(diff: -2))
      rows = described_class.new(business).rows
      expect(rows.map(&:reversal?)).to eq([ true, false ])
      expect(rows.first.balance_after).to eq(product.stock_in(main))
    end
  end

  describe Inventory::Reports::Purchases do
    it "counts only posted (confirmed, not voided) receipts" do
      kept = receive(qty: 10, cost: 10)
      void(receive(qty: 5, cost: 10))
      create_unposted_documents!

      rows = described_class.new(business).rows
      expect(rows.map(&:receipt)).to eq([ kept ])
      expect(rows.first.total_value).to eq(100)
      expect(rows.first.product_count).to eq(1)
    end

    it "reports paid and outstanding from the settlement ledger" do
      receipt = receive(qty: 10, cost: 10)
      receipt.financial_settlements.create!(amount: 40, settled_at: Time.current, created_by: user)
      row = described_class.new(business).rows.sole
      expect([ row.paid_amount, row.outstanding_amount ]).to eq([ 40, 60 ])
      expect(row.outstanding_amount).to eq(receipt.remaining_settlement_amount)
    end

    it "honours the date range and supplier filter" do
      receive(qty: 1, on: today - 40)
      receive(qty: 2, on: today)
      expect(described_class.new(business, from: today - 1).rows.size).to eq(1)
      other = business.suppliers.create!(name: "Other")
      expect(described_class.new(business, supplier_id: other.id).rows).to be_empty
    end
  end

  describe Inventory::Reports::SupplierPurchases do
    it "aggregates posted receipts per supplier with last purchase, outstanding and top products" do
      receive(qty: 10, cost: 10, on: today - 5)
      receive(qty: 2, cost: 4, item: idle, on: today)
      create_unposted_documents!

      row = described_class.new(business).rows.sole
      expect(row.supplier).to eq(supplier)
      expect(row.receipt_count).to eq(2)
      expect(row.total_value).to eq(108)
      expect(row.last_purchase_on).to eq(today)
      expect(row.outstanding_amount).to eq(108)
      expect(row.top_products.map(&:first)).to eq([ product, idle ])
    end
  end

  describe Inventory::Reports::Overview do
    it "headline figures match the underlying reports and the ledger" do
      receive(qty: 20)
      issue(qty: 16)          # 4 left → low stock (reorder level 5)
      idle                    # never moved → out of stock
      create_unposted_documents!

      overview = described_class.new(business)
      expect(overview.total_value).to eq(40)
      expect(overview.product_count).to eq(2)
      expect(overview.low_stock_count).to eq(Inventory::LowStockQuery.new(business).alerts.size)
      expect(overview.out_of_stock_count).to eq(1)
      expect(overview.todays_movement_count).to eq(2)
      expect(overview.month_purchase_value).to eq(200)
      expect(overview.month_consumption_value).to eq(160)
    end
  end
end
