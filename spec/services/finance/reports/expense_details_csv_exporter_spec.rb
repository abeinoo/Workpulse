require "rails_helper"

RSpec.describe Finance::Reports::ExpenseDetailsCsvExporter, type: :model do
  let(:business)  { create(:business) }
  let(:branch)    { create(:branch, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Dye", sku: "DYE-1", initial_cost_price: 0, average_cost_price: 0) }
  let(:year)  { Date.current.year }
  let(:month) { Date.current.month }
  let(:employee) { create(:user, business: business) }
  let(:period_start) { Date.new(year, month, 1) }

  before do
    period = create(:payroll_period, business: business, period_year: year, period_month: month)
    create(:payroll_entry, payroll_period: period, user: employee, base_salary: 5000, total_overtime: 0, total_bonuses: 0, net_salary: 5000)
    create(:shift_assignment, user: employee, branch: branch, effective_from: period_start - 1.month, effective_to: nil)

    business.inventory_movements.create!(product: product, warehouse: warehouse, branch: branch,
      direction: "out", reason: "stock_issue", quantity: 10, unit_cost: 12, occurred_on: Date.current)

    create(:expense, :approved, business: business, branch: branch, amount: 1000, expense_date: Date.current)
  end

  subject(:csv) do
    result = Finance::Reports::ExpenseDetails.new(business, year: year, month: month).call
    described_class.new(result).to_csv
  end

  it "is BOM-prefixed for Excel" do
    expect(csv.byteslice(0, described_class::BOM.bytesize)).to eq(described_class::BOM)
  end

  it "has a header row" do
    header = CSV.parse(csv.delete_prefix(described_class::BOM)).first
    expect(header).to include("Section", "Branch", "Amount")
  end

  it "includes one leaf row per employee and per expense, plus subtotal/grand-total rows" do
    rows = CSV.parse(csv.delete_prefix(described_class::BOM))
    expect(rows.flatten).to include(employee.full_name)
    expect(rows.flatten.map(&:to_s)).to include("1000.0").or include(a_string_matching(/1000/))
    # At least one subtotal ("Total") row per branch group and one grand-total row per section.
    total_label = I18n.t("finance.reports.total")
    expect(rows.count { |r| r.include?(total_label) }).to be >= 2
  end
end
