require "rails_helper"

RSpec.describe Inventory::StockCountApprover, type: :model do
  let(:business)  { create(:business) }
  # Exactly one :owner per business (see spec/support … owner-trait note).
  let(:owner)     { create(:user, :owner, business: business) }
  let(:counter)   { user_with_stock_permissions(business, :view_inventory, :manage_stock_counts) }
  let(:approver)  { user_with_stock_permissions(business, :view_inventory, :post_stock_counts) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:outlet)    { business.warehouses.create!(name: "Outlet") }
  let(:p1)        { business.products.create!(name: "A", sku: "A-1", initial_cost_price: 10, average_cost_price: 10) }
  let(:p2)        { business.products.create!(name: "B", sku: "B-1", initial_cost_price: 5, average_cost_price: 5) }

  def receive!(product, qty, into: warehouse)
    r = business.goods_receipts.build(warehouse: into, received_on: Date.current)
    r.items.build(product: product, quantity: qty, unit_cost: product.average_cost_price)
    expect(Inventory::GoodsReceiptPoster.new(r).call.ok?).to be(true)
  end

  def issue!(product, qty)
    branch = business.branches.first || business.branches.create!(name: "Branch", active: true)
    i = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current)
    i.items.build(product: product, quantity: qty)
    expect(approve_and_post_stock_issue(i).ok?).to be(true)
  end

  def transfer_out!(product, qty)
    t = business.stock_transfers.build(source_warehouse: warehouse, destination_warehouse: outlet, transferred_on: Date.current)
    t.items.build(product: product, quantity: qty)
    expect(Inventory::StockTransferPoster.new(t).call.ok?).to be(true)
  end

  def completed_count(*lines)
    record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: lines, complete: true)
  end

  before do
    receive!(p1, 20)
    receive!(p2, 8)
  end

  describe "posting the counted differences" do
    it "posts one stock-count adjustment from the non-zero differences and lands stock on the counts" do
      count  = completed_count([ p1, 18 ], [ p2, 8 ])   # p1 short by 2, p2 matches
      result = approve_stock_count(count, approver)

      expect(result.ok?).to be(true)
      expect(count.reload).to be_approved
      adjustment = count.active_stock_adjustment
      expect(adjustment).to have_attributes(reason: "stock_count", stock_count_id: count.id, created_by_id: approver.id)
      expect(adjustment.items.map { |i| [ i.product, i.quantity_difference ] }).to eq([ [ p1, -2 ] ])
      expect([ p1.stock_in(warehouse), p2.stock_in(warehouse) ]).to eq([ 18, 8 ])
      movement = adjustment.inventory_movements.sole
      expect(movement).to have_attributes(reason: "adjustment", direction: "out", quantity: 2, product_id: p1.id,
                                          warehouse_id: warehouse.id)
    end

    it "increases stock for an overage" do
      count = completed_count([ p2, 11 ])
      expect(approve_stock_count(count, approver).ok?).to be(true)
      expect(p2.stock_in(warehouse)).to eq(11)
      expect(count.reload.active_stock_adjustment.inventory_movements.sole).to have_attributes(direction: "in", quantity: 3)
    end

    it "approves a perfectly matching count with no adjustment and no movement" do
      count = completed_count([ p1, 20 ], [ p2, 8 ])
      expect { approve_stock_count(count, approver) }.not_to change(InventoryMovement, :count)
      expect(count.reload).to be_approved
      expect(count.stock_adjustments).to be_empty
    end

    it "skips uncounted rows — no adjustment line, stock untouched" do
      count = completed_count([ p1, 15 ])                # p2 preloaded but left blank
      approve_stock_count(count, approver)
      expect(count.reload.active_stock_adjustment.items.map(&:product)).to eq([ p1 ])
      expect(p2.stock_in(warehouse)).to eq(8)
    end

    it "does not change the average cost (variances are valued at the average)" do
      count = completed_count([ p1, 18 ])
      expect { approve_stock_count(count, approver) }.not_to change { p1.reload.average_cost_price }
    end
  end

  describe "decision D2: movements after the count are preserved" do
    it "keeps a receipt posted after counting (4 counted 3, +10 received → −1, final 13)" do
      product = business.products.create!(name: "C", sku: "C-1", initial_cost_price: 2, average_cost_price: 2)
      receive!(product, 4)
      count = completed_count([ product, 3 ])
      receive!(product, 10)

      expect(approve_stock_count(count, approver).ok?).to be(true)
      expect(count.reload.active_stock_adjustment.items.sole.quantity_difference).to eq(-1)
      expect(product.stock_in(warehouse)).to eq(13)
    end

    it "keeps an issue posted after counting" do
      count = completed_count([ p1, 18 ])   # baseline 20 → −2
      issue!(p1, 5)                          # 15 on hand
      approve_stock_count(count, approver)
      expect(p1.stock_in(warehouse)).to eq(13)
    end

    it "keeps a transfer out posted after counting" do
      count = completed_count([ p1, 22 ])   # baseline 20 → +2
      transfer_out!(p1, 6)                   # 14 on hand
      approve_stock_count(count, approver)
      expect([ p1.stock_in(warehouse), p1.stock_in(outlet) ]).to eq([ 16, 6 ])
    end

    it "keeps several later movements across products counted at different times" do
      count = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [])
      travel_to(1.hour.ago) { record_counts!(count, counter, [ [ p1, 19 ] ]) }   # p1 baseline 20
      receive!(p1, 5)                                                         # 25
      receive!(p2, 2)                                                         # 10
      record_counts!(count, counter, [ [ p2, 9 ] ])                           # p2 baseline 10 (after the receipt)
      issue!(p1, 3)                                                           # 22
      complete_stock_count!(count, counter)

      items = count.reload.items.index_by(&:product_id)
      expect(items[p1.id].counted_at).to be < items[p2.id].counted_at
      expect([ items[p1.id].system_quantity, items[p2.id].system_quantity ]).to eq([ 20, 10 ])

      approve_stock_count(count, approver)
      expect([ p1.stock_in(warehouse), p2.stock_in(warehouse) ]).to eq([ 21, 9 ])
    end

    it "refuses (and writes nothing) when later movements left too little stock for the shortage" do
      count = completed_count([ p2, 3 ])   # baseline 8 → −5
      issue!(p2, 6)                         # only 2 left
      result = nil
      expect { result = approve_stock_count(count, approver) }.not_to change(InventoryMovement, :count)
      expect(result.ok?).to be(false)
      expect(result.error).to match(/available/i)
      expect(count.reload).to be_completed
      expect(StockAdjustment.where(stock_count: count)).to be_empty
    end
  end

  describe "transitions and idempotency" do
    it "refuses a count that is not completed" do
      count = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [ [ p1, 5 ] ])
      result = approve_stock_count(count, approver)
      expect(result.ok?).to be(false)
      expect(result.error).to eq(I18n.t("inventory.stock_counts.errors.not_completed"))
    end

    it "cannot be approved twice — the second call fails and only one adjustment exists" do
      count = completed_count([ p1, 18 ])
      expect(approve_stock_count(count, approver).ok?).to be(true)
      expect(approve_stock_count(count, approver).ok?).to be(false)
      expect(StockAdjustment.where(stock_count: count).count).to eq(1)
      expect(p1.stock_in(warehouse)).to eq(18)
    end

    it "refuses a completed count that somehow already owns an active adjustment" do
      count = completed_count([ p1, 18 ])
      stray = business.stock_adjustments.build(warehouse: warehouse, stock_count: count, adjusted_on: Date.current,
                                               reason: "stock_count", created_by: approver)
      stray.items.build(product: p1, quantity_difference: 1)
      expect(Inventory::AdjustmentPoster.new(stray).call.ok?).to be(true)

      result = approve_stock_count(count, approver)
      expect(result.error).to eq(I18n.t("inventory.stock_counts.errors.already_approved"))
      expect(count.reload).to be_completed
    end

    it "the database refuses a second active adjustment for one count" do
      count = completed_count([ p1, 18 ])
      approve_stock_count(count, approver)
      dup = business.stock_adjustments.build(warehouse: warehouse, stock_count: count, adjusted_on: Date.current,
                                             reason: "stock_count", adjustment_number: "ADJ-DUP")
      dup.items.build(product: p1, quantity_difference: 1, unit_cost: 1)
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "segregation of duties (decision D1)" do
    it "blocks the submitter from approving their own count" do
      count  = completed_count([ p1, 18 ])
      result = approve_stock_count(count, counter)
      expect(result.ok?).to be(false)
      expect(result.error).to eq(Approvals::SelfApproval.error_message)
      expect(count.reload).to be_completed
    end

    it "blocks an ordinary approver who ran the count, even when someone else submitted it" do
      count = record_stock_count!(business: business, warehouse: warehouse, counter: approver, lines: [ [ p1, 18 ] ])
      complete_stock_count!(count, counter)
      expect(approve_stock_count(count, approver).ok?).to be(false)
      expect(count.reload).to be_completed
    end

    it "lets the business owner approve their own count, audited as an explicit exception" do
      count = record_stock_count!(business: business, warehouse: warehouse, counter: owner, lines: [ [ p1, 18 ] ],
                                  complete: true)
      expect(approve_stock_count(count, owner).ok?).to be(true)
      entry = AuditLog.for_auditable(count).find_by!(action: "approve")
      expect(entry.actor).to eq(owner)
      expect(entry.metadata).to include("owner_self_approval" => true, "self_approval_exception" => "business_owner")
    end

    it "records an ordinary approval as not an exception" do
      count = completed_count([ p1, 18 ])
      approve_stock_count(count, approver)
      entry = AuditLog.for_auditable(count).find_by!(action: "approve")
      expect(entry.metadata).to include("owner_self_approval" => false, "adjustment_number" => count.reload.active_stock_adjustment.adjustment_number)
      expect(entry.metadata).not_to have_key("self_approval_exception")
    end
  end

  describe "legacy completed counts (submitted before per-product count times)" do
    it "must be reopened and completed again before approval" do
      count = business.stock_counts.build(warehouse: warehouse, counted_on: Date.current, created_by: counter,
                                          status: :completed, completed_by: counter, completed_at: 1.day.ago)
      count.items.build(product: p1, system_quantity: 20, counted_quantity: 12)   # legacy: no source / time
      count.save!

      result = approve_stock_count(count, approver)
      expect(result.ok?).to be(false)
      expect(result.error).to eq(I18n.t("inventory.stock_counts.errors.legacy_requires_recompletion", count: 1))
      expect(p1.stock_in(warehouse)).to eq(20)
    end
  end
end
