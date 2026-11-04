require "rails_helper"

# Unallocated (business-level) costs in the finance reports: floating
# employees' salaries and unallocated expenses (their employer insurance) stay
# off every branch — the first branch included — appear on their own
# "Unallocated" line, and are counted exactly once in the business-wide totals.
#
#   branches A / B / C : expenses 50,000 / 40,000 / 30,000; A's employee 1,000 gross
#   unallocated        : 5,000 insurance expense + 3,000 floating gross salary
RSpec.describe "Finance reports — unallocated costs" do
  let(:business) { create(:business) }
  let!(:branch_a) { create(:branch, business: business, name: "A") } # lowest id: the old fallback branch
  let!(:branch_b) { create(:branch, business: business, name: "B") }
  let!(:branch_c) { create(:branch, business: business, name: "C") }
  let(:year)  { Date.current.year }
  let(:month) { Date.current.month }
  let(:shift) { create(:shift, :hour_based, business: business) }
  let(:period) { create(:payroll_period, business: business, period_year: year, period_month: month) }
  let(:category) { create(:expense_category, business: business) }

  let(:regular)  { create(:user, business: business) }
  let(:floating) { create(:user, business: business) }

  before do
    { branch_a => 50_000, branch_b => 40_000, branch_c => 30_000 }.each do |branch, amount|
      create(:expense, :approved, business: business, branch: branch, amount: amount, expense_category: category)
    end
    create(:expense, :approved, business: business, branch: nil, amount: 5_000, expense_category: category,
                                source_payroll_period: period, unallocated: true)

    start = Date.new(year, month, 1) - 1.month
    create(:shift_assignment, user: regular, branch: branch_a, shift: shift, effective_from: start)
    create(:shift_assignment, :floating, user: floating, shift: shift, effective_from: start)
    create(:payroll_entry, payroll_period: period, user: regular, base_salary: 1_000, total_overtime: 0, total_bonuses: 0, net_salary: 1_000)
    create(:payroll_entry, payroll_period: period, user: floating, base_salary: 2_500, total_overtime: 300, total_bonuses: 200, net_salary: 3_000)
  end

  describe Finance::Reports::ExpenseSummary do
    subject(:table) { described_class.new(business, group_by: :branch, from: Date.current.beginning_of_month, to: Date.current.end_of_month).call }

    it "keeps the branch rows, adds an Unallocated line and totals 125,000" do
      expect(table.rows.to_h { |r| [ r[:label], r[:total] ] }).to eq("A" => 50_000, "B" => 40_000, "C" => 30_000)
      expect(table.unallocated).to include(label: I18n.t("finance.reports.unallocated"), total: 5_000, count: 1)
      expect(table.totals).to eq(count: 4, total: 125_000)
    end

    it "exports the Unallocated line to CSV, once" do
      csv = Finance::Reports::CsvExporter.new(table).to_csv

      expect(csv.scan(I18n.t("finance.reports.unallocated")).size).to eq(1)
      expect(csv).to include("125000")
    end
  end

  describe Finance::Reports::BranchProfitability do
    def table(**opts) = described_class.new(business, year: year, month: month, **opts).call

    it "attributes no unallocated cost to any branch, the first branch included" do
      rows = table.rows.index_by { |r| r[:branch] }

      expect(rows.transform_values { |r| r[:expenses] }).to eq("A" => 50_000, "B" => 40_000, "C" => 30_000)
      expect(rows.transform_values { |r| r[:payroll] }).to eq("A" => 1_000, "B" => 0, "C" => 0)
    end

    it "shows the unallocated costs on their own line and counts them once in the totals" do
      result = table

      expect(result.unallocated).to include(branch: I18n.t("finance.reports.unallocated"), payroll: 3_000,
                                            expenses: 5_000, net: -8_000)
      expect(result.totals).to include(expenses: 125_000, payroll: 4_000, net: -129_000)
    end

    it "withholds the floating salary from a viewer without business-wide payroll access" do
      result = table(payroll_branch_ids: [ branch_a.id, branch_b.id, branch_c.id ])

      expect(result.unallocated).to include(payroll: nil, net: nil, expenses: 5_000)
      expect(result.totals[:payroll]).to be_nil
      expect(result.totals[:expenses]).to eq(125_000)
    end
  end

  describe Finance::Reports::ExpenseDetails do
    def details(**opts) = described_class.new(business, year: year, month: month, **opts).call
    def section(result, key) = result.sections.find { |s| s.key == key }
    def unallocated_group(section) = section.groups.find { |g| g.label == I18n.t("finance.reports.unallocated") }

    it "lists the unallocated costs as their own groups and still reconciles with Branch Profitability" do
      result = details

      payroll = section(result, :payroll)
      expect(payroll.total).to eq(4_000)
      expect(unallocated_group(payroll).rows.map { |r| r[:employee_name] }).to eq([ floating.full_name ])

      expenses = section(result, :branch_expenses)
      expect(expenses.total).to eq(125_000)
      expect(unallocated_group(expenses).subtotal).to eq(5_000)

      expect(section(result, :other).total).to eq(0) # not mistaken for an unattributed legacy expense
      expect(result.reconciliation).to be_matches
      expect(result.reconciliation.report_total).to eq(129_000)
    end

    it "leaves the unallocated costs out of a single branch's view, which still reconciles" do
      result = details(branch_id: branch_a.id)

      expect(unallocated_group(section(result, :payroll))).to be_nil
      expect(unallocated_group(section(result, :branch_expenses))).to be_nil
      expect(section(result, :payroll).total).to eq(1_000)
      expect(result.reconciliation).to be_matches
    end
  end

  it "counts salary and insurance in different figures, never both (no double counting)" do
    sources = Finance::Reports::ExpenseSources.new(business, year: year, month: month)

    expect(sources.unallocated_payroll_cost).to eq(3_000) # gross salary only
    expect(sources.unallocated_expenses).to eq(5_000)     # the insurance expense only
    expect(sources.payroll_costs.values.sum).to eq(1_000)
    expect(sources.direct_expenses.values.sum + sources.allocated_expenses.values.sum).to eq(120_000)
  end
end
