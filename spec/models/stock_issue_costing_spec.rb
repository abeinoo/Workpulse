require "rails_helper"

# Stock Issue costing: a line is valued under the inventory module's single
# valuation method — the product's moving weighted-average cost
# (Inventory::ProductCostUpdater / ProductCostRecalculator). Before posting the
# value is an estimate at current average; posting freezes it onto the item
# and the OUT movement. The selling price is never used as a cost.
RSpec.describe "Stock Issue costing", type: :model do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:branch)    { business.branches.create!(name: "Nasr City", active: true) }

  def product!(sku:, initial_cost: 0, markup: 0)
    business.products.create!(name: "Product #{sku}", sku: sku, initial_cost_price: initial_cost,
                              average_cost_price: initial_cost, selling_markup_percentage: markup)
  end

  def receive!(product, qty, unit_cost)
    receipt = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    receipt.items.build(product: product, quantity: qty, unit_cost: unit_cost)
    expect(Inventory::GoodsReceiptPoster.new(receipt).call).to be_ok
  end

  def draft_issue!(product, qty)
    issue = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current)
    issue.items.build(product: product, quantity: qty)
    issue.save!
    issue
  end

  describe "A. selling price is not the cost" do
    it "values the line at the average cost, not the (higher) selling price" do
      product = product!(sku: "SP-1", markup: 50)
      receive!(product, 10, 20)
      product.reload
      expect(product.selling_price).to eq(30) # 20 * 1.5
      expect(product.average_cost_price).to eq(20)

      item = draft_issue!(product, 2).items.first
      expect(item.effective_unit_cost).to eq(20)
      expect(item.effective_unit_cost).not_to eq(product.selling_price)
    end
  end

  describe "B. goods-receipt valuation" do
    it "reproduces ISS-000100: a draft line uses the moving average instead of 0.00" do
      # UYN1's real history: opening 11 @ 30, 3 out, received 2 @ 35 -> avg 31.
      product = product!(sku: "UYN1", initial_cost: 30)
      receive!(product, 8, 30)
      receive!(product, 2, 35)
      expect(product.reload.average_cost_price).to eq(31)

      issue = draft_issue!(product, 2)
      item  = issue.items.first

      expect(item.unit_cost).to eq(0) # stored placeholder is untouched pre-posting
      expect(item.effective_unit_cost).to eq(31)
      expect(issue.total_value).to eq(62)
      expect(issue).to be_cost_estimated
    end

    it "posts the same cost onto the item and the OUT movement (matching stock reports)" do
      product = product!(sku: "GR-2")
      receive!(product, 10, 100)
      receive!(product, 10, 120)

      issue = draft_issue!(product, 4)
      estimate = issue.items.first.effective_unit_cost
      issue.update!(status: :approved)
      expect(Inventory::StockIssuePoster.new(issue).call).to be_ok

      item     = issue.reload.items.first
      movement = issue.inventory_movements.sole
      expect(item.unit_cost).to eq(110)
      expect(item.effective_unit_cost).to eq(estimate)
      expect(movement.unit_cost).to eq(item.unit_cost)
      expect(issue).not_to be_cost_estimated
    end

    it "keeps a posted issue's frozen cost when the average later moves" do
      product = product!(sku: "FRZ")
      receive!(product, 10, 10)
      issue = draft_issue!(product, 1)
      issue.update!(status: :approved)
      Inventory::StockIssuePoster.new(issue).call

      receive!(product, 10, 50) # average moves to (9*10 + 10*50)/19
      expect(product.reload.average_cost_price).not_to eq(10)

      item = issue.reload.items.first
      expect(item.effective_unit_cost).to eq(10)
      expect(issue.total_value).to eq(10)
    end
  end

  describe "C. total = quantity x unit cost" do
    it "multiplies per line and sums across lines" do
      a = product!(sku: "QA")
      b = product!(sku: "QB")
      receive!(a, 10, "12.5")
      receive!(b, 10, 3)

      issue = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current)
      issue.items.build(product: a, quantity: 3)
      issue.items.build(product: b, quantity: 4)
      issue.save!

      totals = issue.items.map(&:effective_total_cost)
      expect(totals).to contain_exactly(BigDecimal("37.5"), BigDecimal("12"))
      expect(issue.total_value).to eq(BigDecimal("49.5"))

      issue.update!(status: :approved)
      Inventory::StockIssuePoster.new(issue).call
      expect(issue.reload.items.map(&:total_cost)).to contain_exactly(BigDecimal("37.5"), BigDecimal("12"))
      expect(issue.total_value).to eq(BigDecimal("49.5"))
    end
  end

  describe "D. no cost data" do
    it "reports cost unavailable instead of inventing one from the selling price" do
      product = product!(sku: "NOCOST", markup: 25)
      issue   = draft_issue!(product, 2)
      item    = issue.items.first

      expect(item.effective_unit_cost).to be_nil
      expect(item.effective_total_cost).to be_nil
      expect(item).to be_cost_unavailable
      expect(issue).to be_cost_unavailable
      expect(issue.total_value).to eq(0)
    end
  end

  describe "E. stock and valuation are unchanged by viewing a draft" do
    it "does not move stock, write movements, or touch product cost" do
      product = product!(sku: "E-1")
      receive!(product, 10, 20)
      before = product.reload.attributes.slice("average_cost_price", "last_purchase_price")

      issue = draft_issue!(product, 3)
      issue.total_value
      issue.items.each(&:effective_unit_cost)

      expect(product.reload.current_stock).to eq(10)
      expect(product.attributes.slice("average_cost_price", "last_purchase_price")).to eq(before)
      expect(issue.inventory_movements).to be_empty
      expect(InventoryMovement.where(product: product).count).to eq(1)
    end
  end
end
