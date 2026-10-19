require "rails_helper"

# Guards added by the laundry cost-report security fix: exactly one ACTIVE
# laundry branch, every component restricted to it, and include_payroll: false
# never computing payroll or anything derived from it.
RSpec.describe Finance::Reports::LaundryCostSummary, type: :model do
  let(:business)        { create(:business) }
  let!(:laundry_branch) { create(:branch, business: business, branch_type: "laundry") }
  let(:category)        { create(:expense_category, business: business) }

  let(:from) { Date.current.beginning_of_month }
  let(:to)   { Date.current.end_of_month }

  def run(**options)
    described_class.new(business, from: from, to: to, **options).call
  end

  def laundry_payroll!(branch:, net_salary:, biz: business)
    user = create(:user, business: biz)
    create(:shift_assignment, business: biz, user: user, branch: branch,
                              effective_from: from - 1.month, effective_to: nil)
    period = PayrollPeriod.find_by(business: biz, period_year: from.year, period_month: from.month) ||
             create(:payroll_period, :finalized, business: biz, branch: nil,
                                                 period_year: from.year, period_month: from.month)
    create(:payroll_entry, payroll_period: period, user: user, net_salary: net_salary)
  end

  def material_issue!(branch:, biz: business, quantity: 3)
    warehouse = biz.warehouses.create!(name: "WH #{SecureRandom.hex(3)}")
    product   = biz.products.create!(name: "P #{SecureRandom.hex(3)}", sku: SecureRandom.hex(4), unit_of_measure: "kg",
                                     initial_cost_price: 20, average_cost_price: 20)
    receipt = biz.goods_receipts.build(warehouse: warehouse, received_on: from + 1.day)
    receipt.items.build(product: product, quantity: 50, unit_cost: 20)
    Inventory::GoodsReceiptPoster.new(receipt).call
    issue = biz.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: from + 2.days)
    issue.items.build(product: product, quantity: quantity)
    approve_and_post_stock_issue(issue).issue
  end

  describe "laundry branch selection" do
    it "reports the single active laundry branch normally" do
      result = run

      expect(result.has_laundry_branch?).to be(true)
      expect(result.multiple_laundry_branches?).to be(false)
      expect(result.laundry_branch).to eq(laundry_branch)
    end

    it "returns the existing empty result when the only laundry branch is inactive" do
      laundry_branch.update_column(:active, false)
      result = run

      expect(result.has_laundry_branch?).to be(false)
      expect(result.multiple_laundry_branches?).to be(false)
    end

    it "blocks with no figures computed when two active laundry branches exist" do
      create(:branch, business: business, branch_type: "laundry")
      laundry_payroll!(branch: laundry_branch, net_salary: 1000)
      expect(PayrollEntry).not_to receive(:where)
      expect(StockIssue).not_to receive(:for_business)

      result = run

      expect(result.multiple_laundry_branches?).to be(true)
      expect(result.has_laundry_branch?).to be(false)
      expect(result.to_h.except(:multiple_laundry_branches).values.compact).to be_empty
    end

    it "ignores an inactive second laundry branch, and its payroll, expenses and materials" do
      old_laundry = create(:branch, :inactive, business: business, branch_type: "laundry")
      laundry_payroll!(branch: old_laundry, net_salary: 900)
      create(:expense, :approved, business: business, branch: old_laundry, expense_category: category,
                                  amount: 70, expense_date: from + 2.days)
      material_issue!(branch: old_laundry)

      laundry_payroll!(branch: laundry_branch, net_salary: 1000)
      create(:expense, :approved, business: business, branch: laundry_branch, expense_category: category,
                                  amount: 50, expense_date: from + 2.days)
      material_issue!(branch: laundry_branch, quantity: 2)

      result = run

      expect(result.laundry_branch).to eq(laundry_branch)
      expect(result.payroll_cost).to eq(1000)
      expect(result.direct_expenses).to eq(50)
      expect(result.material_cost).to eq(40)
      expect(result.material_lines.map { |l| l.stock_issue.branch_id }.uniq).to eq([ laundry_branch.id ])
    end

    it "does not count another business's active laundry branch" do
      create(:branch, business: create(:business), branch_type: "laundry")

      expect(run.multiple_laundry_branches?).to be(false)
    end
  end

  describe "include_payroll: false" do
    before do
      laundry_payroll!(branch: laundry_branch, net_salary: 1000)
      create(:expense, :approved, business: business, branch: laundry_branch, expense_category: category,
                                  amount: 50, expense_date: from + 2.days)
      material_issue!(branch: laundry_branch, quantity: 2)
    end

    it "never computes payroll or any figure derived from it" do
      expect(PayrollPeriod).not_to receive(:for_business)
      expect(PayrollEntry).not_to receive(:where)

      result = run(include_payroll: false)

      expect(result.payroll_included?).to be(false)
      expect(result.payroll_cost).to be_nil
      expect(result.payroll_periods).to be_nil
      expect(result.actual_operating_cost).to be_nil
      expect(result.coverage_variance).to be_nil
      expect(result.actual_cost_per_towel).to be_nil
    end

    it "keeps the independently calculable figures" do
      result = run(include_payroll: false)

      expect(result.direct_expenses).to eq(50)
      expect(result.material_cost).to eq(40)
      expect(result.standard_cost).to eq(0)
      expect(result.standard_towels).to eq(0)
    end

    it "matches the full report's independent figures, and the full report includes payroll" do
      restricted = run(include_payroll: false)
      full       = run

      expect(full.payroll_included?).to be(true)
      expect(full.payroll_cost).to eq(1000)
      expect(full.actual_operating_cost).to eq(1000 + 50 + 40)
      %i[direct_expenses material_cost standard_cost standard_towels].each do |field|
        expect(restricted.public_send(field)).to eq(full.public_send(field))
      end
    end

    it "carries the payroll flag on the empty result" do
      laundry_branch.update_column(:active, false)

      expect(run(include_payroll: false).payroll_included?).to be(false)
      expect(run.payroll_included?).to be(true)
    end
  end

  describe "cross-business isolation" do
    it "never counts another business's payroll, expenses or stock issues" do
      other  = create(:business)
      other_laundry = create(:branch, business: other, branch_type: "laundry")
      laundry_payroll!(branch: other_laundry, net_salary: 5000, biz: other)
      create(:expense, :approved, business: other, branch: other_laundry,
                                  expense_category: create(:expense_category, business: other),
                                  amount: 300, expense_date: from + 2.days)
      material_issue!(branch: other_laundry, biz: other)

      result = run

      expect(result.payroll_cost).to eq(0)
      expect(result.direct_expenses).to eq(0)
      expect(result.material_cost).to eq(0)
      expect(result.material_lines).to be_empty
    end
  end
end
