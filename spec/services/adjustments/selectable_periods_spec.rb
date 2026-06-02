require "rails_helper"

RSpec.describe Adjustments::SelectablePeriods, type: :model do
  let(:business) { create(:business) }
  let(:today)    { Date.new(2026, 6, 15) }

  def keys(business_arg = business)
    described_class.new(business_arg, today: today).options.map(&:last)
  end

  it "offers the current month plus the next three months by default" do
    expect(keys).to eq(%w[2026-6 2026-7 2026-8 2026-9])
  end

  it "excludes a month whose payroll has been finalized" do
    create(:payroll_period, :finalized, business: business, period_month: 7, period_year: 2026)
    expect(keys).not_to include("2026-7")
  end

  it "excludes a month whose payroll has been paid" do
    create(:payroll_period, :paid, business: business, period_month: 6, period_year: 2026)
    expect(keys).not_to include("2026-6")
  end

  it "excludes a month that is under review" do
    create(:payroll_period, business: business, status: "under_review", period_month: 8, period_year: 2026)
    expect(keys).not_to include("2026-8")
  end

  it "keeps a month that still has a draft period" do
    create(:payroll_period, business: business, status: "draft", period_month: 6, period_year: 2026)
    expect(keys).to include("2026-6")
  end

  it "surfaces an older still-open draft period outside the forward window" do
    create(:payroll_period, business: business, status: "draft", period_month: 2, period_year: 2026)
    expect(keys).to include("2026-2")
  end
end
