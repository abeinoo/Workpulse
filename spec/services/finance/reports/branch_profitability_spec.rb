require "rails_helper"

RSpec.describe Finance::Reports::BranchProfitability, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:other)    { create(:branch, business: business) }
  let(:category) { create(:expense_category, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Dye", sku: "DYE-1", initial_cost_price: 0, average_cost_price: 0) }
  let(:year)  { Date.current.year }
  let(:month) { Date.current.month }

  before do
    # Revenue 9000
    create(:branch_revenue, business: business, branch: branch, period_month: Date.current.beginning_of_month, amount: 9000)

    # Payroll gross = base 5000 + OT 300 + bonus 200 = 5500
    period = create(:payroll_period, business: business, branch: branch, period_year: year, period_month: month)
    create(:payroll_entry, payroll_period: period, base_salary: 5000, total_overtime: 300, total_bonuses: 200, net_salary: 5500)

    # Inventory CONSUMPTION = 10 * 12 = 120 (OUT / stock_issue)
    business.inventory_movements.create!(product: product, warehouse: warehouse, branch: branch,
      direction: "out", reason: "stock_issue", quantity: 10, unit_cost: 12, occurred_on: Date.current)
    # A purchase (IN / goods_receipt) must NOT count as cost
    business.inventory_movements.create!(product: product, warehouse: warehouse, branch: branch,
      direction: "in", reason: "goods_receipt", quantity: 5, unit_cost: 100, occurred_on: Date.current)

    # Direct branch expense 1000 (approved)
    create(:expense, :approved, business: business, branch: branch, amount: 1000, expense_date: Date.current)
    # Shared expense 200 split 50/50 -> 100 allocated to this branch
    shared = build(:expense, :approved, business: business, branch: nil, amount: 200, expense_date: Date.current)
    shared.expense_allocations.build(branch: branch, allocation_percentage: 50, allocated_amount: 100)
    shared.expense_allocations.build(branch: other, allocation_percentage: 50, allocated_amount: 100)
    shared.save!
  end

  subject(:rows) { described_class.new(business, year: year, month: month).call.rows }

  it "computes Net = Revenue - Payroll - Inventory consumption - Branch expenses" do
    row = rows.find { |r| r[:branch] == branch.name }
    expect(row[:revenue]).to   eq(9000)
    expect(row[:payroll]).to   eq(5500)
    expect(row[:inventory]).to eq(120)            # consumption only, excludes the 500 purchase
    expect(row[:expenses]).to  eq(1100)           # 1000 direct + 100 allocated share
    expect(row[:net]).to       eq(9000 - 5500 - 120 - 1100)  # 2280
  end

  it "reconciles the totals row to the sum of branch rows" do
    table = described_class.new(business, year: year, month: month).call
    %i[revenue payroll inventory expenses net].each do |col|
      expect(table.totals[col]).to eq(table.rows.sum { |r| r[col] })
    end
  end

  it "excludes draft/pending expenses from committed cost" do
    create(:expense, :pending, business: business, branch: branch, amount: 9999, expense_date: Date.current)
    row = described_class.new(business, year: year, month: month).call.rows.find { |r| r[:branch] == branch.name }
    expect(row[:expenses]).to eq(1100)
  end
end
