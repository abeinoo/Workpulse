require "rails_helper"

RSpec.describe Payroll::AdvanceDeductor do
  let(:business) { create(:business) }
  let(:user)     { create(:user, business: business) }

  let(:august_period) do
    create(:payroll_period, business: business, period_year: 2026, period_month: 8)
  end

  let(:september_period) do
    create(:payroll_period, business: business, period_year: 2026, period_month: 9)
  end

  def build_advance(issued_at:)
    create(:advance, user: user, issued_at: issued_at)
  end

  def deduct(period)
    described_class.call(user: user, period: period)
  end

  # Simulates what EntryCalculator does with the result: persist the line item
  # against a real PayrollEntry so the "already reserved elsewhere" check has
  # something to find.
  def deduct_and_persist(period)
    result = deduct(period)
    entry  = create(:payroll_entry, payroll_period: period, user: user)
    result.line_items.each { |attrs| entry.payroll_line_items.create!(attrs) }
    result
  end

  describe "a repayment generated in one period" do
    let!(:advance) { build_advance(issued_at: Date.new(2026, 8, 16)) }

    it "is deducted once when only the August period exists" do
      result = deduct(august_period)
      expect(result.total_amount).to eq(1_000.0)
      expect(result.line_items.size).to eq(1)
    end

    it "is not deducted again from September once it is already reserved in the unpaid August period" do
      deduct_and_persist(august_period)

      result = deduct(september_period)

      expect(result.total_amount).to eq(0.0)
      expect(result.line_items).to be_empty
    end
  end

  describe "an advance created in August whose first deduction run is September" do
    let!(:advance) { build_advance(issued_at: Date.new(2026, 8, 20)) }

    it "is deducted in September when September is the first period generated for it" do
      result = deduct(september_period)

      expect(result.total_amount).to eq(1_000.0)
      expect(result.line_items.first[:source_id]).to eq(advance.id)
    end
  end

  describe "once the holding period is paid" do
    let!(:advance) { build_advance(issued_at: Date.new(2026, 8, 16)) }

    it "is eligible again if it still has a remaining balance after settlement" do
      deduct_and_persist(august_period)

      # Approver#settle_advances! reduces remaining_amount to 0 on full repayment;
      # emulate a still-outstanding balance (e.g. a manual correction) to prove
      # a *paid* period never blocks re-selection, only an unpaid one does.
      august_period.update!(status: "paid")
      advance.update!(remaining_amount: 400.0)

      result = deduct(september_period)

      expect(result.total_amount).to eq(400.0)
    end
  end

  describe "a fully repaid advance" do
    let!(:advance) { build_advance(issued_at: Date.new(2026, 8, 16)) }

    it "is never deducted again" do
      advance.update!(remaining_amount: 0, status: "fully_repaid")

      result = deduct(september_period)

      expect(result.total_amount).to eq(0.0)
    end
  end
end
