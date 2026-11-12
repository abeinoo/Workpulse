require "rails_helper"

# Two regressions found on SC-000008 (dev DB):
#   1. A legacy row whose ledger on-hand is fractional (4.004 after a 0.004
#      receipt) made Complete fail: D9 adopted the exact ledger quantity and the
#      whole-number rule — meant for quantities people enter — rejected it.
#   2. After a reopen, saving the counting sheet with a system-derived row
#      unchanged re-stamped it as a physical count against the current on-hand,
#      creating a false variance.
# Quantities are never rounded: 4.004 stays BigDecimal("4.004").
RSpec.describe "Stock count fractional and system-derived quantities", type: :model do
  let(:business)  { create(:business) }
  let(:counter)   { user_with_stock_permissions(business, :view_inventory, :manage_stock_counts) }
  let(:approver)  { user_with_stock_permissions(business, :view_inventory, :post_stock_counts) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:serum)     { business.products.create!(name: "Serum", sku: "GKM-84978", initial_cost_price: 50, average_cost_price: 50) }
  let(:wax)       { business.products.create!(name: "Wax", sku: "WX-1", initial_cost_price: 2, average_cost_price: 2) }
  let(:gel)       { business.products.create!(name: "Gel", sku: "GL-1", initial_cost_price: 3, average_cost_price: 3) }

  def receive!(product, qty)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: product, quantity: qty, unit_cost: product.average_cost_price)
    expect(Inventory::GoodsReceiptPoster.new(r).call.ok?).to be(true)
  end

  # A pre-repair count: quantities with no source and no count time.
  def legacy_count(status: :in_progress, lines:)
    count = business.stock_counts.build(warehouse: warehouse, counted_on: Date.current, created_by: counter,
                                        status: status, completed_by: (counter if status == :completed),
                                        completed_at: (1.day.ago if status == :completed))
    lines.each { |product, system, counted| count.items.build(product: product, system_quantity: system, counted_quantity: counted) }
    count.save!
    count
  end

  def complete(count) = Inventory::StockCountCompletion.new(stock_count_id: count.id, actor: counter).call
  def item_for(count, product) = count.reload.items.find_by!(product: product)

  before do
    receive!(serum, 4)
    receive!(serum, BigDecimal("0.004"))   # the fractional receipt (cf. GRN-000029), kept exactly
    receive!(wax, 7)
    receive!(gel, 5)
    expect(serum.stock_in(warehouse)).to eq(BigDecimal("4.004"))
  end

  describe "bug 1: completing a legacy count with a fractional ledger on-hand" do
    let(:count) { legacy_count(lines: [ [ serum, 4, 3 ], [ wax, 7, 5 ], [ gel, 5, 4 ] ]) }

    it "completes, keeping the exact system quantity on a system-derived row with zero difference" do
      record_counts!(count, counter, [ [ gel, 6 ] ])            # one physical recount among the legacy rows
      result = complete(count)

      expect(result.ok?).to be(true)
      expect(count.reload).to be_completed
      serum_item = item_for(count, serum)
      expect(serum_item.quantity_source).to eq("system")
      expect(serum_item.counted_quantity).to eq(BigDecimal("4.004"))
      expect(serum_item.counted_quantity).to be_a(BigDecimal)
      expect(serum_item.system_quantity).to eq(BigDecimal("4.004"))
      expect(serum_item.difference).to eq(0)
      expect(serum_item.legacy_counted_quantity).to eq(3)
    end

    it "processes the other products correctly and posts no line for the fractional row" do
      record_counts!(count, counter, [ [ gel, 6 ] ])            # gel +1
      complete(count)
      expect(item_for(count, wax)).to have_attributes(quantity_source: "system", counted_quantity: 7, difference: 0)
      expect(item_for(count, gel)).to have_attributes(quantity_source: "physical", counted_quantity: 6, difference: 1)

      expect(approve_stock_count(count, approver).ok?).to be(true)
      lines = count.reload.active_stock_adjustment.items.map { |i| [ i.product_id, i.quantity_difference ] }
      expect(lines).to eq([ [ gel.id, 1 ] ])
      expect(serum.stock_in(warehouse)).to eq(BigDecimal("4.004"))
      expect([ wax.stock_in(warehouse), gel.stock_in(warehouse) ]).to eq([ 7, 6 ])
    end

    it "still rejects a fractional quantity entered by a person, naming the product" do
      result = Inventory::StockCountRecorder.new(stock_count_id: count.id, actor: counter,
                                                 entries: [ { product_id: wax.id, counted_quantity: "2.5" } ]).call
      expect(result.ok?).to be(false)
      expect(result.error).to eq("WX-1: Counted quantity must be an integer")
      expect(item_for(count, wax)).to have_attributes(counted_quantity: 5, quantity_source: nil)
    end

    it "keeps the whole-number rule for physical rows at the model level" do
      item = item_for(count, wax)
      item.assign_attributes(counted_quantity: BigDecimal("2.5"), quantity_source: "physical")
      expect(item).not_to be_valid
      expect(item.errors.details[:counted_quantity]).to include(error: :not_an_integer)
      item.quantity_source = nil                                 # a legacy / unsourced entry too
      expect(item).not_to be_valid
    end

    it "posts exactly −1.004 when the fractional product is physically recounted as 3" do
      record_counts!(count, counter, [ [ serum, 3 ] ])
      expect(item_for(count, serum)).to have_attributes(quantity_source: "physical", system_quantity: BigDecimal("4.004"),
                                                        difference: BigDecimal("-1.004"), legacy_counted_quantity: 3)
      complete(count)
      expect(approve_stock_count(count, approver).ok?).to be(true)

      line = count.reload.active_stock_adjustment.items.find_by!(product: serum)
      expect(line.quantity_difference).to eq(BigDecimal("-1.004"))
      expect(line.stock_adjustment.inventory_movements.find_by!(product: serum).quantity).to eq(BigDecimal("1.004"))
      expect(serum.stock_in(warehouse)).to eq(3)
    end

    it "works for an old Completed count after it is reopened and completed again" do
      old = legacy_count(status: :completed, lines: [ [ serum, 4, 3 ], [ wax, 7, 5 ] ])
      expect(approve_stock_count(old, approver).ok?).to be(false)          # legacy rows block approval
      expect(reopen_stock_count(old, approver, reason: nil).ok?).to be(true)
      expect(complete(old).ok?).to be(true)

      expect(item_for(old, serum)).to have_attributes(quantity_source: "system", counted_quantity: BigDecimal("4.004"), difference: 0)
      expect(approve_stock_count(old, approver).ok?).to be(true)
      expect(old.reload.stock_adjustments).to be_empty                    # nothing recounted → nothing posted
      expect(serum.stock_in(warehouse)).to eq(BigDecimal("4.004"))
    end
  end

  describe "bug 2: re-saving an unchanged system-derived row after a reopen" do
    let(:count) { legacy_count(lines: [ [ wax, 7, 5 ], [ serum, 4, 3 ] ]) }

    before do
      complete(count)                                            # wax adopts 7, serum 4.004
      expect(reopen_stock_count(count, approver, reason: nil).ok?).to be(true)
      receive!(wax, 1)                                           # after the reopen: wax 8
    end

    def save_sheet(entries) =
      Inventory::StockCountRecorder.new(stock_count_id: count.id, actor: counter, entries: entries).call

    it "keeps an unchanged row system-derived — same source, time, baseline and zero difference" do
      before = item_for(count, wax).attributes.slice("quantity_source", "counted_at", "baseline_at", "system_quantity", "difference", "counted_quantity")
      travel_to(1.hour.from_now) do
        expect(save_sheet([ { id: item_for(count, wax).id, counted_quantity: "7" },
                            { id: item_for(count, serum).id, counted_quantity: "4.004" } ]).ok?).to be(true)
      end
      expect(item_for(count, wax).attributes.slice(*before.keys)).to eq(before)
      expect(item_for(count, serum)).to have_attributes(quantity_source: "system", counted_quantity: BigDecimal("4.004"), difference: 0)
    end

    it "keeps a system-derived row when the sheet sends it blank (the form leaves it unfilled)" do
      save_sheet([ { id: item_for(count, wax).id, counted_quantity: "" } ])
      expect(item_for(count, wax)).to have_attributes(quantity_source: "system", counted_quantity: 7, difference: 0)
    end

    it "preserves the receipt after the reopen and posts no false variance" do
      save_sheet([ { id: item_for(count, wax).id, counted_quantity: "7" } ])
      complete(count)
      expect(approve_stock_count(count, approver).ok?).to be(true)
      expect(count.reload.stock_adjustments).to be_empty
      expect(wax.stock_in(warehouse)).to eq(8)
    end

    it "records a genuinely changed quantity as a physical recount with a new time and baseline" do
      now = 1.hour.from_now.change(usec: 0)
      travel_to(now) { save_sheet([ { id: item_for(count, wax).id, counted_quantity: "6" } ]) }
      expect(item_for(count, wax)).to have_attributes(quantity_source: "physical", counted_quantity: 6,
                                                      system_quantity: 8, difference: -2, counted_at: now)
      complete(count)
      approve_stock_count(count, approver)
      expect(wax.stock_in(warehouse)).to eq(6)
    end
  end

  describe "completion errors" do
    it "name the product whose row could not be saved" do
      count = legacy_count(lines: [ [ wax, 7, 5 ] ])
      business.products.create!(name: "Wax mini", sku: "WX-1-M", parent_product_id: wax.id,
                                initial_cost_price: 2, average_cost_price: 2)   # wax became a product family
      result = complete(count)
      expect(result.ok?).to be(false)
      expect(result.error).to start_with("WX-1: ")
      expect(result.error).not_to match(/ActiveRecord|Validation failed/)
      expect(count.reload).to be_in_progress
    end
  end
end
