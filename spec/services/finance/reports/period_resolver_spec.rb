require "rails_helper"

RSpec.describe Finance::Reports::PeriodResolver, type: :model do
  describe "single_month (default/backward-compatible)" do
    it "resolves to the given month/year for both from and to when no period_type is given" do
      period = described_class.call(month: "7", year: "2026")

      expect(period.type).to eq("single_month")
      expect(period.from_year).to eq(2026)
      expect(period.from_month).to eq(7)
      expect(period.to_year).to eq(2026)
      expect(period.to_month).to eq(7)
      expect(period).to be_single_month
      expect(period).to be_valid
    end

    it "defaults to the current month/year when nothing is given" do
      period = described_class.call({})
      expect(period.from_year).to eq(Date.current.year)
      expect(period.from_month).to eq(Date.current.month)
    end

    it "treats an unrecognized period_type as single_month" do
      period = described_class.call(period_type: "not_a_real_type", month: "3", year: "2026")
      expect(period.type).to eq("single_month")
      expect(period.from_month).to eq(3)
    end
  end

  describe "presets" do
    it "last_3_months spans the anchor month and the 2 preceding months, inclusive" do
      period = described_class.call(period_type: "last_3_months", month: "7", year: "2026")

      expect(period.from_year).to eq(2026)
      expect(period.from_month).to eq(5)
      expect(period.to_year).to eq(2026)
      expect(period.to_month).to eq(7)
      expect(period).not_to be_single_month
    end

    it "last_6_months spans the anchor month and the 5 preceding months" do
      period = described_class.call(period_type: "last_6_months", month: "7", year: "2026")
      expect(period.from_year).to eq(2026)
      expect(period.from_month).to eq(2)
      expect(period.to_month).to eq(7)
    end

    it "last_12_months spans the anchor month and the 11 preceding months, crossing a year boundary" do
      period = described_class.call(period_type: "last_12_months", month: "3", year: "2026")
      expect(period.from_year).to eq(2025)
      expect(period.from_month).to eq(4)
      expect(period.to_year).to eq(2026)
      expect(period.to_month).to eq(3)
    end
  end

  describe "custom" do
    it "resolves an explicit from/to range" do
      period = described_class.call(period_type: "custom", from_year: "2026", from_month: "5", to_year: "2026", to_month: "7")
      expect(period.from_year).to eq(2026)
      expect(period.from_month).to eq(5)
      expect(period.to_year).to eq(2026)
      expect(period.to_month).to eq(7)
      expect(period).to be_valid
    end

    it "flags an inverted range (from after to) as invalid with an Arabic message" do
      period = described_class.call(period_type: "custom", from_year: "2026", from_month: "8", to_year: "2026", to_month: "5")
      expect(period).not_to be_valid
      expect(period.error).to be_present
    end

    it "accepts an equal from/to as a valid single-month custom range" do
      period = described_class.call(period_type: "custom", from_year: "2026", from_month: "6", to_year: "2026", to_month: "6")
      expect(period).to be_valid
      expect(period).to be_single_month
    end
  end

  describe "#label" do
    it "renders a single month label" do
      period = described_class.call(month: "7", year: "2026")
      expect(period.label).to eq(I18n.l(Date.new(2026, 7, 1), format: "%B %Y"))
    end

    it "renders a from → to range label for a multi-month period" do
      period = described_class.call(period_type: "last_3_months", month: "7", year: "2026")
      expected = "#{I18n.l(Date.new(2026, 5, 1), format: '%B %Y')} → #{I18n.l(Date.new(2026, 7, 1), format: '%B %Y')}"
      expect(period.label).to eq(expected)
    end
  end
end
