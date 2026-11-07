require "rails_helper"

# R2 (attendance-requirements-and-cost-allocation plan): pins the rounding of
# the three remainder-on-last-row splits — AllocationCalculator's equal
# percentages and amounts-from-percentages, and PayrollInsuranceExpense's
# percentages-from-amounts — so the extraction to Finance::MoneySplitter is
# provably behaviour-preserving. Values were recorded against the code before
# the extraction: each row but the last is rounded to 2 dp (half away from
# zero), the last row takes the exact residual, in input order.
RSpec.describe "Finance allocation rounding (characterization)", type: :model do
  let(:business) { create(:business) }
  let(:branches) { create_list(:branch, 7, business: business) }

  def d(values) = values.map { |v| v&.to_d }

  describe Finance::AllocationCalculator do
    def equal_split(amount, count)
      expense = build(:expense, business: business, amount: amount)
      branches.first(count).each { |br| expense.expense_allocations.build(branch: br) }
      described_class.new(expense, mode: :equal).call
      expense.expense_allocations
    end

    def percentage_split(amount, percentages)
      expense = build(:expense, business: business, amount: amount)
      percentages.each_with_index do |pct, i|
        expense.expense_allocations.build(branch: branches[i], allocation_percentage: pct)
      end
      described_class.new(expense, mode: :percentage).call
      expense.expense_allocations.map(&:allocated_amount)
    end

    it "equal mode: seven branches put the percentage and amount residuals on the last row" do
      rows = equal_split(1000, 7)
      expect(rows.map(&:allocation_percentage)).to eq(d(%w[14.29 14.29 14.29 14.29 14.29 14.29 14.26]))
      expect(rows.map(&:allocated_amount)).to eq(d(%w[142.90 142.90 142.90 142.90 142.90 142.90 142.60]))
    end

    it "equal mode: a total smaller than the row count leaves the last row at zero" do
      rows = equal_split(BigDecimal("0.05"), 6)
      expect(rows.map(&:allocation_percentage)).to eq(d(%w[16.67 16.67 16.67 16.67 16.67 16.65]))
      expect(rows.map(&:allocated_amount)).to eq(d(%w[0.01 0.01 0.01 0.01 0.01 0.00]))
    end

    it "equal mode: a single branch takes 100 % and the whole amount" do
      rows = equal_split(BigDecimal("99.99"), 1)
      expect(rows.map(&:allocation_percentage)).to eq(d(%w[100]))
      expect(rows.map(&:allocated_amount)).to eq(d(%w[99.99]))
    end

    it "equal mode: a negative amount is split with the same signs and residual" do
      expect(equal_split(-100, 3).map(&:allocated_amount)).to eq(d(%w[-33.33 -33.33 -33.34]))
    end

    it "percentage mode: the last row absorbs the residual" do
      expect(percentage_split(BigDecimal("100.01"), [ 33.33, 33.33, 33.34 ])).to eq(d(%w[33.33 33.33 33.35]))
    end

    it "percentage mode: rounds half away from zero" do
      expect(percentage_split(BigDecimal("10.05"), [ 50, 50 ])).to eq(d(%w[5.03 5.02]))
      expect(percentage_split(BigDecimal("-10.05"), [ 50, 50 ])).to eq(d(%w[-5.03 -5.02]))
    end

    it "percentage mode: percentages that do not total 100 still give the last row the remaining amount" do
      expect(percentage_split(100, [ 50, 30 ])).to eq(d(%w[50 50]))
    end

    it "percentage mode: a zero amount gives zero rows; a missing percentage counts as zero" do
      expect(percentage_split(0, [ 25, 25, 50 ])).to eq(d(%w[0 0 0]))
      expect(percentage_split(50, [ nil, 100 ])).to eq(d(%w[0 50]))
    end
  end

  describe Finance::PayrollInsuranceExpense do
    let(:owner) { create(:user, :owner, business: business) }

    # One finalized period per call: the service records at most one active
    # insurance expense per period.
    def percentages_for(amounts, total)
      month  = PayrollPeriod.where(business: business).count + 1
      period = create(:payroll_period, business: business, period_year: 2026, period_month: month, status: "finalized")
      by_branch = amounts.each_with_index.to_h { |amount, i| [ branches[i].id, amount.to_d ] }
      expense = described_class.record(period: period, actor: owner, total: total.to_d, by_branch: by_branch).expense
      by_branch.keys.map { |id| expense.expense_allocations.find { |a| a.branch_id == id }.allocation_percentage }
    end

    it "derives percentages from the exact amounts, the last given branch absorbing the residual" do
      expect(percentages_for(%w[10 20 70.01], "100.01")).to eq(d(%w[10 20 70]))
      expect(percentages_for(%w[1 1 1], "3")).to eq(d(%w[33.33 33.33 33.34]))
    end

    # The largest share (3 of 6) comes first, so a largest-share rule would
    # give it the -0.01 residual (49.99) instead of the last branch.
    it "keeps the residual on the last given branch, not the largest share" do
      expect(percentages_for(%w[3 1 1 1], "6")).to eq(d(%w[50 16.67 16.67 16.66]))
    end
  end
end
