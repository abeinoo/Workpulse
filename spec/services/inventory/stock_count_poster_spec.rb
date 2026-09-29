require "rails_helper"

RSpec.describe Inventory::StockCountPoster, type: :model do
  let(:business)  { create(:business) }
  let(:user)      { create(:user, :super_admin, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:p1)        { business.products.create!(name: "A", sku: "A-1", initial_cost_price: 10, average_cost_price: 10) }
  let(:p2)        { business.products.create!(name: "B", sku: "B-1", initial_cost_price: 5, average_cost_price: 5) }

  before do
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: p1, quantity: 20, unit_cost: 10)
    r.items.build(product: p2, quantity: 8,  unit_cost: 5)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  def count_with(*lines)
    c = business.stock_counts.build(warehouse: warehouse, counted_on: Date.current, created_by: user)
    lines.each { |product, counted| c.items.build(product: product, counted_quantity: counted) }
    c.save!
    c
  end

  describe "#call" do
    it "posts variances as a single stock-count adjustment and corrects stock" do
      count = count_with([ p1, 18 ], [ p2, 8 ])          # p1 short by 2, p2 matches
      result = described_class.new(count, user: user).call

      expect(result.ok?).to be(true)
      expect(count.reload).to be_posted
      expect(count.posted_by).to eq(user)
      expect(count.posted_at).to be_present
      expect(p1.reload.current_stock).to eq(18)          # corrected down
      expect(p2.reload.current_stock).to eq(8)           # untouched
    end

    it "links a generated adjustment containing only the non-zero variances" do
      count = count_with([ p1, 25 ], [ p2, 8 ])          # p1 surplus +5, p2 match
      described_class.new(count, user: user).call

      adj = count.reload.stock_adjustment
      expect(adj).to be_present
      expect(adj.reason).to eq("stock_count")
      expect(adj.items.count).to eq(1)
      expect(adj.items.first.product).to eq(p1)
      expect(adj.items.first.quantity_difference).to eq(5)
      expect(p1.reload.current_stock).to eq(25)
    end

    it "does not change the average cost (variances are valued at avg)" do
      count = count_with([ p1, 15 ])
      expect { described_class.new(count, user: user).call }.not_to change { p1.reload.average_cost_price }
    end

    it "posts a perfectly matching count with no adjustment" do
      count = count_with([ p1, 20 ], [ p2, 8 ])
      result = described_class.new(count, user: user).call
      expect(result.ok?).to be(true)
      expect(count.reload.stock_adjustment).to be_nil
      expect(business.stock_adjustments.count).to eq(0)
    end

    it "recomputes system quantity at post time, not from the stale snapshot" do
      count = count_with([ p1, 20 ])                     # snapshot system=20, counted=20 (diff 0)
      # Stock changes after the count was drafted: issue 5 → live system now 15.
      i = business.stock_issues.build(warehouse: warehouse, issued_on: Date.current)
      i.items.build(product: p1, quantity: 5)
      approve_and_post_stock_issue(i)

      described_class.new(count, user: user).call
      # Counted 20 vs live 15 → +5 applied, ending at the counted 20.
      expect(p1.reload.current_stock).to eq(20)
      expect(count.reload.stock_adjustment.items.first.quantity_difference).to eq(5)
    end

    it "refuses to post a non-draft count" do
      count = count_with([ p1, 18 ])
      described_class.new(count, user: user).call
      result = described_class.new(count.reload, user: user).call
      expect(result.ok?).to be(false)
    end
  end
end
