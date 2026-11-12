require "rails_helper"
require Rails.root.join("db/migrate/20261112100000_link_stock_adjustments_to_stock_counts")

# The backfill in LinkStockAdjustmentsToStockCounts links a historical
# stock-count adjustment to its count only when the pre-repair link
# (stock_counts.stock_adjustment_id) is unambiguous — never a guess.
RSpec.describe "LinkStockAdjustmentsToStockCounts backfill" do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:annex)     { business.warehouses.create!(name: "Annex") }
  let(:product)   { business.products.create!(name: "P", sku: "P-1", initial_cost_price: 1, average_cost_price: 1) }

  # Pre-repair shapes are written without the new create-time validations.
  def legacy_adjustment(reason: "stock_count", in_warehouse: warehouse)
    StockAdjustment.new(business: business, warehouse: in_warehouse, adjusted_on: Date.current, reason: reason,
                        adjustment_number: "ADJ-#{SecureRandom.hex(3)}").tap { |a| a.save!(validate: false) }
  end

  def legacy_count(adjustment, in_warehouse: warehouse)
    count = business.stock_counts.build(warehouse: in_warehouse, counted_on: Date.current, status: :completed)
    count.items.build(product: product, system_quantity: 1, counted_quantity: 1)
    count.save!
    count.update_columns(status: "approved", stock_adjustment_id: adjustment.id)
    count
  end

  def backfill! = ActiveRecord::Base.connection.execute(LinkStockAdjustmentsToStockCounts::BACKFILL_SQL)

  it "links an adjustment named by exactly one count of the same business and warehouse" do
    adjustment = legacy_adjustment
    count      = legacy_count(adjustment)
    backfill!
    expect(adjustment.reload.stock_count_id).to eq(count.id)
    expect(count.reload.stock_adjustment_id).to eq(adjustment.id)   # legacy column untouched
  end

  it "leaves ambiguous or mismatched relationships unlinked" do
    shared   = legacy_adjustment
    2.times { legacy_count(shared) }                                   # named by two counts
    manual   = legacy_adjustment                                       # "stock_count" reason, no count at all
    damaged  = legacy_adjustment(reason: "damaged")
    legacy_count(damaged)                                              # wrong reason
    elsewhere = legacy_adjustment(in_warehouse: annex)
    legacy_count(elsewhere)                                            # warehouse mismatch

    backfill!
    expect([ shared, manual, damaged, elsewhere ].map { |a| a.reload.stock_count_id }).to all(be_nil)
  end

  it "is idempotent" do
    adjustment = legacy_adjustment
    legacy_count(adjustment)
    backfill!
    expect(backfill!.cmd_tuples).to eq(0)
  end
end
