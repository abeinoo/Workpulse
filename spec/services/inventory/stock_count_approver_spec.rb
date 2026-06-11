require "rails_helper"

RSpec.describe Inventory::StockCountApprover, type: :model do
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

  # Builds a count, enters the counts, and advances it to "completed" (ready to approve).
  def completed_count(*lines)
    c = business.stock_counts.build(warehouse: warehouse, counted_on: Date.current, created_by: user)
    lines.each { |product, counted| c.items.build(product: product, counted_quantity: counted) }
    c.save!
    c.start_counting!(user)
    c.mark_completed!(user)
    c
  end

  describe "#call" do
    it "approves variances as a single stock-count adjustment and corrects stock" do
      count = completed_count([ p1, 18 ], [ p2, 8 ])     # p1 short by 2, p2 matches
      result = described_class.new(count, user: user).call

      expect(result.ok?).to be(true)
      expect(count.reload).to be_approved
      expect(count.approved_by).to eq(user)
      expect(count.approved_at).to be_present
      expect(p1.reload.current_stock).to eq(18)          # corrected down
      expect(p2.reload.current_stock).to eq(8)           # untouched
    end

    it "links a generated adjustment containing only the non-zero variances" do
      count = completed_count([ p1, 25 ], [ p2, 8 ])     # p1 surplus +5, p2 match
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
      count = completed_count([ p1, 15 ])
      expect { described_class.new(count, user: user).call }.not_to change { p1.reload.average_cost_price }
    end

    it "approves a perfectly matching count with no adjustment" do
      count = completed_count([ p1, 20 ], [ p2, 8 ])
      result = described_class.new(count, user: user).call
      expect(result.ok?).to be(true)
      expect(count.reload.stock_adjustment).to be_nil
      expect(business.stock_adjustments.count).to eq(0)
    end

    it "recomputes system quantity at approval time, not from the stale snapshot" do
      count = completed_count([ p1, 20 ])                 # snapshot system=20, counted=20 (diff 0)
      # Stock changes after the count was taken: issue 5 → live system now 15.
      i = business.stock_issues.build(warehouse: warehouse, issued_on: Date.current)
      i.items.build(product: p1, quantity: 5)
      Inventory::StockIssuePoster.new(i).call

      described_class.new(count, user: user).call
      # Counted 20 vs live 15 → +5 applied, ending at the counted 20.
      expect(p1.reload.current_stock).to eq(20)
      expect(count.reload.stock_adjustment.items.first.quantity_difference).to eq(5)
    end

    it "skips uncounted (blank) rows — no adjustment line, stock untouched" do
      c = business.stock_counts.build(warehouse: warehouse, counted_on: Date.current, created_by: user)
      c.items.build(product: p1, counted_quantity: 18)   # counted: −2
      c.items.build(product: p2)                          # uncounted (blank)
      c.save!
      c.start_counting!(user)
      c.mark_completed!(user)

      result = described_class.new(c, user: user).call
      expect(result.ok?).to be(true)
      expect(c.reload).to be_approved
      expect(p1.reload.current_stock).to eq(18)           # corrected
      expect(p2.reload.current_stock).to eq(8)            # untouched
      expect(c.stock_adjustment.items.map(&:product)).to eq([ p1 ])
    end

    it "refuses to approve a count that is not completed" do
      count = completed_count([ p1, 18 ])
      described_class.new(count, user: user).call        # → approved
      result = described_class.new(count.reload, user: user).call
      expect(result.ok?).to be(false)
    end
  end

  describe "count ⇄ adjustment integration" do
    it "links the count and the generated adjustment both ways" do
      count = completed_count([ p1, 18 ])
      described_class.new(count, user: user).call
      adj = count.reload.stock_adjustment

      expect(adj).to be_present
      expect(adj.source_stock_count).to eq(count)        # adjustment → count
      expect(count.stock_adjustment).to eq(adj)          # count → adjustment
    end

    it "exposes shortage / overage / net value from the frozen unit-cost snapshot" do
      count = completed_count([ p1, 18 ], [ p2, 13 ])    # p1 −2 @10 = −20; p2 +5 @5 = +25
      described_class.new(count, user: user).call
      adj = count.reload.stock_adjustment

      expect(adj.shortage_value).to eq(-20)
      expect(adj.overage_value).to eq(25)
      expect(adj.net_value).to eq(5)
    end
  end

  describe "duplicate prevention (req 6 & 7)" do
    it "cannot be approved twice — second call fails, only one adjustment exists" do
      count = completed_count([ p1, 18 ])
      expect(described_class.new(count, user: user).call.ok?).to be(true)

      before = business.stock_adjustments.count
      result = described_class.new(count.reload, user: user).call
      expect(result.ok?).to be(false)
      expect(business.stock_adjustments.count).to eq(before)   # no second adjustment
    end

    it "an approved count cannot be reopened (so it can never spawn a 2nd adjustment)" do
      count = completed_count([ p1, 18 ])
      described_class.new(count, user: user).call
      expect(count.reload).to be_approved
      expect(count.reopen!).to be(false)                  # reopen only works from completed
      expect(count.reload).to be_approved
    end

    it "refuses to approve a completed count that somehow already owns an adjustment" do
      count = completed_count([ p1, 18 ])
      other = business.stock_adjustments.create!(warehouse: warehouse, adjusted_on: Date.current,
                                                 reason: :manual_correction, adjustment_number: "ADJ-X",
                                                 items_attributes: { "0" => { product_id: p1.id, quantity_difference: 1, unit_cost: 10 } })
      count.update_column(:stock_adjustment_id, other.id)

      result = described_class.new(count.reload, user: user).call
      expect(result.ok?).to be(false)
      expect(count.errors[:base].join).to match(/already/i)
    end
  end
end
