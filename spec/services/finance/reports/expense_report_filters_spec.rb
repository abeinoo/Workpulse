require "rails_helper"

RSpec.describe Finance::Reports::ExpenseReportFilters do
  let(:business) { create(:business) }
  let(:today)    { Date.new(2026, 10, 23) }

  def resolve(today: self.today, **params)
    described_class.new(business, ActionController::Parameters.new(params), today: today).call
  end

  def d(str) = Date.parse(str)

  describe "presets (whole calendar months, calendar-aligned comparison)" do
    it "defaults to the last 6 months — the range these reports have always used" do
      result = resolve
      expect(result).to have_attributes(preset: "last_6_months", from: d("2026-05-01"), to: d("2026-10-31"),
                                        previous_from: d("2025-11-01"), previous_to: d("2026-04-30"), error: nil)
    end

    it "current_month: 1st to last day of this month, vs the previous month" do
      expect(resolve(period: "current_month"))
        .to have_attributes(from: d("2026-10-01"), to: d("2026-10-31"), previous_from: d("2026-09-01"), previous_to: d("2026-09-30"))
    end

    it "previous_month: the complete previous calendar month, vs the month before it" do
      expect(resolve(period: "previous_month"))
        .to have_attributes(from: d("2026-09-01"), to: d("2026-09-30"), previous_from: d("2026-08-01"), previous_to: d("2026-08-31"))
    end

    it "previous_month in January is the previous year's December" do
      expect(resolve(period: "previous_month", today: d("2027-01-15")))
        .to have_attributes(from: d("2026-12-01"), to: d("2026-12-31"), previous_from: d("2026-11-01"), previous_to: d("2026-11-30"))
    end

    it "last_3_months: this month and the 2 before, vs the 3 months before that" do
      expect(resolve(period: "last_3_months"))
        .to have_attributes(from: d("2026-08-01"), to: d("2026-10-31"), previous_from: d("2026-05-01"), previous_to: d("2026-07-31"))
    end

    it "last_6_months: this month and the 5 before, vs the 6 months before that" do
      expect(resolve(period: "last_6_months"))
        .to have_attributes(from: d("2026-05-01"), to: d("2026-10-31"), previous_from: d("2025-11-01"), previous_to: d("2026-04-30"))
    end

    it "current_year: 1 Jan to 31 Dec, vs the previous year" do
      expect(resolve(period: "current_year"))
        .to have_attributes(from: d("2026-01-01"), to: d("2026-12-31"), previous_from: d("2025-01-01"), previous_to: d("2025-12-31"))
    end

    it "handles month-end anchors (31st) without overflow" do
      expect(resolve(period: "last_3_months", today: d("2026-05-31")))
        .to have_attributes(from: d("2026-03-01"), to: d("2026-05-31"), previous_from: d("2025-12-01"), previous_to: d("2026-02-28"))
    end

    it "treats an unknown period as the default" do
      expect(resolve(period: "last_99_years")).to have_attributes(preset: "last_6_months", from: d("2026-05-01"), error: nil)
    end
  end

  describe "business timezone and day roll-over" do
    # 2026-09-30 22:30 UTC is 2026-10-01 01:30 in Riyadh (UTC+3).
    let(:instant) { Time.utc(2026, 9, 30, 22, 30) }

    it "uses the business's local date, not UTC" do
      business.update!(timezone: "Asia/Riyadh", business_day_start_hour: 0)
      travel_to(instant) do
        result = described_class.new(business, ActionController::Parameters.new(period: "current_month")).call
        expect(result).to have_attributes(from: d("2026-10-01"), to: d("2026-10-31"))
      end
    end

    it "keeps the previous business day before the business day start hour" do
      business.update!(timezone: "Asia/Riyadh", business_day_start_hour: 6)
      travel_to(instant) do
        result = described_class.new(business, ActionController::Parameters.new(period: "current_month")).call
        expect(result).to have_attributes(from: d("2026-09-01"), to: d("2026-09-30"))
      end
    end
  end

  describe "custom range" do
    it "uses the submitted inclusive dates, compared with the equal-length run of days before" do
      expect(resolve(period: "custom", from: "2026-03-10", to: "2026-03-19"))
        .to have_attributes(preset: "custom", from: d("2026-03-10"), to: d("2026-03-19"),
                            previous_from: d("2026-02-28"), previous_to: d("2026-03-09"), error: nil)
    end

    it "accepts a single-day range" do
      expect(resolve(period: "custom", from: "2026-03-10", to: "2026-03-10"))
        .to have_attributes(from: d("2026-03-10"), to: d("2026-03-10"), previous_from: d("2026-03-09"), previous_to: d("2026-03-09"))
    end

    it "treats legacy from/to without a period (e.g. dashboard links) as a custom range" do
      expect(resolve(from: "2026-02-01", to: "2026-02-28")).to have_attributes(preset: "custom", from: d("2026-02-01"), to: d("2026-02-28"))
    end

    it "fills a blank side from the default period, as before" do
      expect(resolve(period: "custom", from: "2026-07-01")).to have_attributes(from: d("2026-07-01"), to: d("2026-10-31"), error: nil)
    end

    it "falls back to the default period with an error for a reversed range" do
      expect(resolve(period: "custom", from: "2026-05-01", to: "2026-04-01"))
        .to have_attributes(preset: "last_6_months", from: d("2026-05-01"), to: d("2026-10-31"),
                            error: I18n.t("finance.reports.expense_filters.errors.reversed_range"))
    end

    [ "2026-02-30", "not-a-date", "99999-01-01", "1066-10-14" ].each do |bad|
      it "falls back to the default period with an error for #{bad.inspect}" do
        expect(resolve(period: "custom", from: bad, to: "2026-06-01"))
          .to have_attributes(preset: "last_6_months", from: d("2026-05-01"),
                              error: I18n.t("finance.reports.expense_filters.errors.invalid_date"))
      end
    end
  end

  describe "branch" do
    let(:branch) { create(:branch, business: business) }

    it "is nil (all branches) when not given" do
      expect(resolve.branch).to be_nil
    end

    it "accepts a branch of the business" do
      expect(resolve(branch_id: branch.id.to_s)).to have_attributes(branch_id: branch.id, error: nil)
    end

    it "accepts an inactive branch of the business (historical expenses)" do
      branch.update_column(:active, false)
      expect(resolve(branch_id: branch.id.to_s).branch_id).to eq(branch.id)
    end

    it "ignores another business's branch and says so" do
      other = create(:branch)
      expect(resolve(branch_id: other.id.to_s))
        .to have_attributes(branch: nil, error: I18n.t("finance.reports.expense_filters.errors.branch_unavailable"))
    end

    [ "abc", "1 OR 1=1", "-1", "1.5" ].each do |junk|
      it "ignores a malformed branch_id #{junk.inspect}" do
        expect(resolve(branch_id: junk)).to have_attributes(branch: nil, error: be_present)
      end
    end

    it "keeps the period error when both are wrong" do
      other = create(:branch)
      expect(resolve(branch_id: other.id.to_s, period: "custom", from: "x").error)
        .to eq(I18n.t("finance.reports.expense_filters.errors.invalid_date"))
    end
  end

  describe "#to_params" do
    it "reproduces exactly the resolved report" do
      branch = create(:branch, business: business)
      expect(resolve(period: "previous_month", branch_id: branch.id.to_s).to_params)
        .to eq(period: "previous_month", from: "2026-09-01", to: "2026-09-30", branch_id: branch.id)
    end
  end
end
