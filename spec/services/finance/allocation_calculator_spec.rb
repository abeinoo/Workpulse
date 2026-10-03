require "rails_helper"

RSpec.describe Finance::AllocationCalculator, type: :model do
  let(:business) { create(:business) }
  let(:b1) { create(:branch, business: business) }
  let(:b2) { create(:branch, business: business) }
  let(:b3) { create(:branch, business: business) }

  def expense_with(amount, branches)
    e = build(:expense, business: business, amount: amount)
    branches.each { |br, pct| e.expense_allocations.build(branch: br, allocation_percentage: pct) }
    e
  end

  describe "equal mode" do
    it "splits evenly and amounts reconcile to the total" do
      e = expense_with(100, { b1 => nil, b2 => nil })
      described_class.new(e, mode: :equal).call
      expect(e.expense_allocations.map { |a| a.allocation_percentage }).to all(eq(50))
      expect(e.expense_allocations.map { |a| a.allocated_amount }).to eq([ 50, 50 ])
      expect(e.expense_allocations.sum(&:allocated_amount)).to eq(100)
    end

    it "absorbs the rounding residual on the last row for an uneven split" do
      e = expense_with(100, { b1 => nil, b2 => nil, b3 => nil })
      described_class.new(e, mode: :equal).call
      amounts     = e.expense_allocations.map(&:allocated_amount)
      percentages = e.expense_allocations.map(&:allocation_percentage)
      expect(amounts.sum).to eq(100)
      expect(amounts).to eq([ 33.33, 33.33, 33.34 ])
      expect(percentages.sum).to eq(100)
      expect(percentages).to eq([ 33.33, 33.33, 33.34 ])
    end
  end

  describe "percentage mode" do
    it "derives amounts from the given percentages" do
      e = expense_with(200, { b1 => 60, b2 => 40 })
      described_class.new(e, mode: :percentage).call
      expect(e.expense_allocations.map(&:allocated_amount)).to eq([ 120, 80 ])
      expect(e.expense_allocations.sum(&:allocated_amount)).to eq(200)
    end
  end

  describe "manual mode" do
    it "derives percentages from the entered amounts" do
      e = build(:expense, business: business, amount: 200)
      e.expense_allocations.build(branch: b1, allocated_amount: 150)
      e.expense_allocations.build(branch: b2, allocated_amount: 50)
      described_class.new(e, mode: :manual).call
      expect(e.expense_allocations.map(&:allocation_percentage)).to eq([ 75, 25 ])
    end

    it "leaves the entered amounts untouched" do
      e = build(:expense, business: business, amount: 100)
      e.expense_allocations.build(branch: b1, allocated_amount: BigDecimal("33.33"))
      e.expense_allocations.build(branch: b2, allocated_amount: BigDecimal("66.67"))
      described_class.new(e, mode: :manual).call
      expect(e.expense_allocations.map(&:allocated_amount)).to eq([ BigDecimal("33.33"), BigDecimal("66.67") ])
    end

    it "keeps derived percentages within 0.01–100 for positive amounts" do
      e = build(:expense, business: business, amount: 20_000)
      e.expense_allocations.build(branch: b1, allocated_amount: BigDecimal("0.50"))
      e.expense_allocations.build(branch: b2, allocated_amount: BigDecimal("30000"))
      described_class.new(e, mode: :manual).call
      expect(e.expense_allocations.map(&:allocation_percentage)).to eq([ BigDecimal("0.01"), BigDecimal(100) ])
    end
  end
end
