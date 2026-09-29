require "rails_helper"

# Stock issue → posted → consumption cost → void / reversal → finance.
# A voided issue must stop contributing to consumption cost everywhere that
# reads Inventory::ConsumptionLedger (inventory reports, product page, Finance
# branch profitability / expense details).
RSpec.describe Inventory::ConsumptionLedger, type: :model do
  let(:business)  { create(:business) }
  let(:user)      { create(:user, :super_admin, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:branch)    { create(:branch, business: business) }
  let(:other)     { create(:branch, business: business) }
  let(:product) do
    business.products.create!(name: "Dye", sku: "DYE-1", initial_cost_price: 12, average_cost_price: 12)
  end
  let(:today)       { BusinessDay.current(context: business) }
  let(:month_start) { today.beginning_of_month }

  before do
    r = business.goods_receipts.build(warehouse: warehouse, received_on: month_start - 2.months)
    r.items.build(product: product, quantity: 100, unit_cost: 12)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  def issue(qty:, on: today, to_branch: branch)
    i = business.stock_issues.build(warehouse: warehouse, branch: to_branch, issued_on: on)
    i.items.build(product: product, quantity: qty)
    approve_and_post_stock_issue(i).tap { |res| expect(res.ok?).to be(true) }.issue
  end

  def void(doc)
    Inventory::DocumentVoider.new(doc, user: user, reason: "wrong branch").call.tap { |res| expect(res.ok?).to be(true) }
  end

  def ledger(**opts) = described_class.new(business, **opts)
  def month_ledger   = ledger(from: month_start, to: month_start.end_of_month)

  def finance_sources
    Finance::Reports::ExpenseSources.new(business, year: month_start.year, month: month_start.month)
  end

  describe "posted stock issue" do
    it "counts as consumption cost for its branch" do
      issue(qty: 10)
      expect(month_ledger.cost_by_branch).to eq(branch.id => 120)
      expect(month_ledger.net_quantity).to eq(10)
    end

    it "ignores unposted issues (draft / pending / approved / rejected / cancelled)" do
      %w[draft pending_approval approved rejected cancelled].each do |status|
        i = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: today, status: status)
        i.items.build(product: product, quantity: 5)
        i.save!
      end
      expect(month_ledger.cost_by_branch).to be_empty
    end
  end

  describe "voided stock issue" do
    it "before the void the cost is counted; after the void it nets to zero" do
      voided = issue(qty: 10)
      expect(month_ledger.cost_by_branch[branch.id]).to eq(120)

      void(voided)
      expect(month_ledger.cost_by_branch[branch.id]).to eq(0)
      expect(month_ledger.net_quantity).to eq(0)
    end

    it "attributes the reversal to the voided issue's branch (reversal rows carry no branch)" do
      issue(qty: 4, to_branch: other)
      void(issue(qty: 10))
      reversal = InventoryMovement.find_by(reason: "reversal")
      expect(reversal.branch_id).to be_nil
      expect(month_ledger.cost_by_branch).to eq(branch.id => 0, other.id => 48)
    end

    it "a void in a later period is a credit in that period; the posting period keeps its history" do
      issued = issue(qty: 10, on: month_start - 1.month)
      void(issued) # dated today's business day
      last_month = ledger(from: month_start - 1.month, to: month_start - 1)
      expect(last_month.cost_by_branch[branch.id]).to eq(120)
      expect(month_ledger.cost_by_branch[branch.id]).to eq(-120)
      expect(ledger.cost_by_branch[branch.id]).to eq(0)
    end

    it "the last consumed date ignores voided issues" do
      issue(qty: 2, on: today - 5)
      void(issue(qty: 3, on: today))
      expect(ledger(product_id: product.id).last_consumed_on).to eq(today - 5)
    end
  end

  describe "finance" do
    it "branch profitability inventory cost excludes a voided issue" do
      issue(qty: 10)
      void(issue(qty: 5))
      expect(finance_sources.inventory_costs[branch.id]).to eq(120)
    end

    it "expense details reconcile to the same net cost and drop fully voided products" do
      kept_product = product
      issue(qty: 10)
      rows = finance_sources.inventory_movements_by_branch_product[branch.id]
      expect(rows.map { |r| [ r[:product], r[:quantity], r[:total] ] }).to eq([ [ kept_product, 10, 120 ] ])

      void(business.stock_issues.last)
      expect(finance_sources.inventory_movements_by_branch_product[branch.id]).to be_blank
      expect(finance_sources.inventory_costs[branch.id]).to eq(0)
    end

    it "BranchProfitability's inventory column matches the ledger" do
      issue(qty: 10)
      void(issue(qty: 5))
      branch.update!(branch_type: "sales", active: true)
      table = Finance::Reports::BranchProfitability.new(business, year: month_start.year, month: month_start.month).call
      row = table.rows.find { |r| r[:branch] == branch.name }
      expect(row[:inventory]).to eq(120)
      expect(row[:inventory]).to eq(month_ledger.cost_by_branch[branch.id])
    end
  end

  describe "inventory consumption report" do
    it "shows issued, reversed and net per branch from the same ledger" do
      issue(qty: 10)
      void(issue(qty: 5))
      row = Inventory::Reports::Consumption.new(business).rows.sole
      expect([ row.branch, row.issued_quantity, row.reversed_quantity, row.net_quantity, row.net_value ])
        .to eq([ branch, 15, 5, 10, 120 ])
    end
  end
end
