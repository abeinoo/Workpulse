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

  describe "#default_key" do
    def default_key(business_arg = business)
      described_class.new(business_arg, today: today).default_key
    end

    it "returns the previous month's key when that period is draft" do
      create(:payroll_period, business: business, status: "draft",
             period_month: 5, period_year: 2026)
      expect(default_key).to eq("2026-5")
    end

    it "returns the current month when the previous month has no period record" do
      expect(default_key).to eq("2026-6")
    end

    it "returns the current month when the previous month's period is finalized" do
      create(:payroll_period, :finalized, business: business,
             period_month: 5, period_year: 2026)
      expect(default_key).to eq("2026-6")
    end

    it "returns the current month when the previous month's period is paid" do
      create(:payroll_period, :paid, business: business,
             period_month: 5, period_year: 2026)
      expect(default_key).to eq("2026-6")
    end

    it "falls back to the first selectable period when both previous and current are locked" do
      create(:payroll_period, :finalized, business: business,
             period_month: 5, period_year: 2026)
      create(:payroll_period, :finalized, business: business,
             period_month: 6, period_year: 2026)
      # Only July onwards remain
      expect(default_key).to eq("2026-7")
    end

    it "returns nil when no periods are selectable at all" do
      [6, 7, 8, 9].each do |m|
        create(:payroll_period, :finalized, business: business,
               period_month: m, period_year: 2026)
      end
      expect(default_key).to be_nil
    end
  end
end
