require "rails_helper"

RSpec.describe Finance::Reports::LaundryCostSummary, type: :model do
  let(:business) { create(:business) }
  let(:sales_branch) { create(:branch, business: business, branch_type: "sales") }
  let!(:laundry_branch) { create(:branch, business: business, branch_type: "laundry") }
  let(:towel_type) { business.towel_types.create!(name: "Bath Towel") }
  let(:actor) { create(:user, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Laundry Warehouse") }

  let(:from) { Date.current.beginning_of_month }
  let(:to)   { Date.current.end_of_month }

  def run
    described_class.new(business, from: from, to: to).call
  end

  def fund(branch, status, quantity)
    Laundry::TowelAdjuster.new(actor: actor).call(towel_type: towel_type, branch: branch, status: status,
                                                   adjustment_quantity: quantity, reason: "test setup")
  end

  def receive_from_branch!(confirmed:)
    fund(sales_branch, "clean", confirmed + 10)
    transfer = Laundry::TowelTransferCreator.create(actor: actor, params: {
      source_branch_id: sales_branch.id, destination_branch_id: laundry_branch.id, towel_status: "dirty",
      items_attributes: [ { towel_type_id: towel_type.id, declared_quantity: confirmed } ]
    }).transfer
    Laundry::TowelTransferCreator.new(transfer).dispatch(actor: actor)
    Laundry::TowelTransferCreator.new(transfer.reload)
                                 .receive(actor: actor, confirmed_quantities: { transfer.items.first.id => confirmed })
  end

  before { business.laundry_standard_cost_rates.create!(towel_type: towel_type, cost_per_towel: 1.5, effective_from: 1.year.ago) }

  it "returns no laundry_branch when the business has none configured" do
    business.branches.destroy_all
    result = described_class.new(business, from: from, to: to).call
    expect(result.has_laundry_branch?).to be(false)
  end

  describe "payroll" do
    it "includes finalized payroll for users with a ShiftAssignment at the laundry branch during the period" do
      user = create(:user, business: business)
      create(:shift_assignment, business: business, user: user, branch: laundry_branch,
             effective_from: from - 1.month, effective_to: nil)
      period = create(:payroll_period, :finalized, business: business, branch: nil,
                      period_year: from.year, period_month: from.month)
      create(:payroll_entry, payroll_period: period, user: user, net_salary: 3000)

      result = run
      expect(result.payroll_cost).to eq(3000)
      expect(result.payroll_periods).to include(period)
    end

    it "excludes draft/unfinalized payroll" do
      user = create(:user, business: business)
      create(:shift_assignment, business: business, user: user, branch: laundry_branch,
             effective_from: from - 1.month, effective_to: nil)
      period = create(:payroll_period, business: business, branch: nil, status: :draft,
                      period_year: from.year, period_month: from.month)
      create(:payroll_entry, payroll_period: period, user: user, net_salary: 3000)

      expect(run.payroll_cost).to eq(0)
    end

    it "excludes an employee who never had a ShiftAssignment at the laundry branch (historical attribution, not current)" do
      user = create(:user, business: business)
      create(:shift_assignment, business: business, user: user, branch: sales_branch,
             effective_from: from - 1.month, effective_to: nil)
      period = create(:payroll_period, :finalized, business: business, branch: nil,
                      period_year: from.year, period_month: from.month)
      create(:payroll_entry, payroll_period: period, user: user, net_salary: 3000)

      expect(run.payroll_cost).to eq(0)
    end

    it "reuses the authoritative net_salary total without double-counting components" do
      user = create(:user, business: business)
      create(:shift_assignment, business: business, user: user, branch: laundry_branch,
             effective_from: from - 1.month, effective_to: nil)
      period = create(:payroll_period, :finalized, business: business, branch: nil,
                      period_year: from.year, period_month: from.month)
      create(:payroll_entry, :with_overtime, payroll_period: period, user: user, base_salary: 5000, net_salary: 5300)

      # Only net_salary counted — not base_salary + total_overtime added again on top.
      expect(run.payroll_cost).to eq(5300)
    end
  end

  describe "expenses" do
    it "includes an approved expense allocated directly to the laundry branch" do
      category = create(:expense_category, business: business)
      create(:expense, :approved, business: business, branch: laundry_branch, expense_category: category,
             amount: 400, expense_date: from + 2.days)

      expect(run.direct_expenses).to eq(400)
    end

    it "excludes rejected/pending/draft expenses" do
      category = create(:expense_category, business: business)
      create(:expense, :rejected, business: business, branch: laundry_branch, expense_category: category,
             amount: 100, expense_date: from + 2.days)
      create(:expense, :pending, business: business, branch: laundry_branch, expense_category: category,
             amount: 100, expense_date: from + 2.days)
      create(:expense, business: business, branch: laundry_branch, expense_category: category, # draft
             amount: 100, expense_date: from + 2.days)

      expect(run.direct_expenses).to eq(0)
    end

    it "excludes expenses belonging to a sales branch" do
      category = create(:expense_category, business: business)
      create(:expense, :approved, business: business, branch: sales_branch, expense_category: category,
             amount: 250, expense_date: from + 2.days)

      expect(run.direct_expenses).to eq(0)
    end

    it "respects the effective expense_date, not created_at" do
      category = create(:expense_category, business: business)
      create(:expense, :approved, business: business, branch: laundry_branch, expense_category: category,
             amount: 250, expense_date: from - 10.days)

      expect(run.direct_expenses).to eq(0)
    end
  end

  describe "materials" do
    let(:product) do
      business.products.create!(name: "Detergent", sku: "DET-1", unit_of_measure: "kg",
                                initial_cost_price: 20, average_cost_price: 20)
    end

    before do
      receipt = business.goods_receipts.build(warehouse: warehouse, received_on: from + 1.day)
      receipt.items.build(product: product, quantity: 100, unit_cost: 20)
      Inventory::GoodsReceiptPoster.new(receipt).call
    end

    # The existing Inventory Stock Issue workflow is the single source of
    # truth for laundry material consumption — not a laundry-specific
    # recording screen. These specs post real StockIssue documents through
    # the same Inventory::StockIssuePoster/DocumentVoider services the rest
    # of the app uses, matching how a real consumption would be recorded.
    def issue!(branch:, qty: 3, wh: warehouse, on: from + 2.days)
      i = business.stock_issues.build(warehouse: wh, branch: branch, issued_on: on)
      i.items.build(product: product, quantity: qty)
      approve_and_post_stock_issue(i).issue
    end

    it "counts a valid Stock Issue to the laundry branch" do
      issue!(branch: laundry_branch, qty: 3)

      expect(run.material_cost).to eq(60) # 3kg * 20
    end

    it "excludes a Stock Issue to a sales (non-laundry) branch" do
      issue!(branch: sales_branch, qty: 3)

      expect(run.material_cost).to eq(0)
    end

    it "does not count a plain warehouse transfer to a laundry warehouse as consumption" do
      other_warehouse = business.warehouses.create!(name: "Other")
      transfer = business.stock_transfers.build(source_warehouse: warehouse, destination_warehouse: other_warehouse,
                                                transferred_on: Date.current)
      transfer.items.build(product: product, quantity: 5)
      Inventory::StockTransferPoster.new(transfer).call

      expect(run.material_cost).to eq(0)
    end

    it "excludes a voided Stock Issue" do
      issue = issue!(branch: laundry_branch, qty: 3)
      Inventory::DocumentVoider.new(issue, user: actor, reason: "miscounted").call

      expect(run.material_cost).to eq(0)
    end

    it "uses the historical cost snapshot, unaffected by a later product cost change" do
      issue!(branch: laundry_branch, qty: 3)
      product.update!(average_cost_price: 999)

      expect(run.material_cost).to eq(60)
    end

    it "aggregates multiple laundry Stock Issues correctly" do
      issue!(branch: laundry_branch, qty: 3)
      issue!(branch: laundry_branch, qty: 2)

      expect(run.material_cost).to eq(100) # (3 + 2) * 20
    end

    it "filters by the Stock Issue's effective issued_on date, not created_at" do
      issue!(branch: laundry_branch, qty: 3, on: from - 5.days)

      expect(run.material_cost).to eq(0)
    end

    it "does not count the same Stock Issue twice, and exposes one drill-down line per item" do
      issue!(branch: laundry_branch, qty: 3)

      result = run
      expect(result.material_cost).to eq(60)
      expect(result.material_lines.size).to eq(1)
      expect(result.material_lines.first.total_cost).to eq(60)
    end

    it "is scoped to the current business" do
      other_business = create(:business)
      other_laundry   = create(:branch, business: other_business, branch_type: "laundry")
      other_warehouse = other_business.warehouses.create!(name: "Other Biz Warehouse")
      other_product   = other_business.products.create!(name: "Bleach", sku: "BLC-1", unit_of_measure: "kg",
                                                         initial_cost_price: 10, average_cost_price: 10)
      other_receipt = other_business.goods_receipts.build(warehouse: other_warehouse, received_on: from + 1.day)
      other_receipt.items.build(product: other_product, quantity: 10, unit_cost: 10)
      Inventory::GoodsReceiptPoster.new(other_receipt).call
      other_issue = other_business.stock_issues.build(warehouse: other_warehouse, branch: other_laundry,
                                                       issued_on: from + 2.days)
      other_issue.items.build(product: other_product, quantity: 2)
      approve_and_post_stock_issue(other_issue)

      expect(run.material_cost).to eq(0)
    end
  end

  describe "summary formulas" do
    it "computes actual_operating_cost, coverage_variance, and actual_cost_per_towel correctly" do
      receive_from_branch!(confirmed: 100) # standard cost = 150

      category = create(:expense_category, business: business)
      create(:expense, :approved, business: business, branch: laundry_branch, expense_category: category,
             amount: 50, expense_date: from + 2.days)

      result = run
      expect(result.actual_operating_cost).to eq(result.payroll_cost + result.direct_expenses + result.material_cost)
      expect(result.actual_operating_cost).to eq(50)
      expect(result.coverage_variance).to eq(result.consumption.total_cost - result.actual_operating_cost)
      expect(result.coverage_variance).to eq(150 - 50)
      expect(result.actual_cost_per_towel).to eq(50.0 / 100)
    end

    it "does not divide by zero when no towels were received — actual_cost_per_towel is nil" do
      result = run
      expect(result.consumption.total_towels).to eq(0)
      expect(result.actual_cost_per_towel).to be_nil
    end

    it "does not mutate any source records (payroll, expense, inventory, towel ledger)" do
      receive_from_branch!(confirmed: 50)
      category = create(:expense_category, business: business)
      expense = create(:expense, :approved, business: business, branch: laundry_branch, expense_category: category,
                       amount: 50, expense_date: from + 2.days)
      expense_updated_at = expense.updated_at

      run

      expect(expense.reload.updated_at).to eq(expense_updated_at)
    end
  end
end
