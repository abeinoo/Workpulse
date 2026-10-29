require "rails_helper"

RSpec.describe Payroll::AutoGenerator do
  # The generator decides on today in the business timezone
  # (Payroll::AutoGenerator#today_in_tz), never the UTC calendar day — they
  # differ every evening (21:00–24:00 UTC for Asia/Riyadh). The clock is
  # pinned to a day of month <= 28: the generate day is set to today's day and
  # Business caps payroll_auto_generate_day at 28, so on the 29th–31st the
  # business record itself would be invalid (BUG-023).
  around { |example| travel_to(Time.utc(2026, 9, 15, 9, 0)) { example.run } } # 12:00 on 15 September in Riyadh

  let(:timezone)       { "Asia/Riyadh" }
  let(:business_today) { ActiveSupport::TimeZone[timezone].today }
  let(:business)       { create(:business, timezone: timezone, payroll_auto_generate_day: business_today.day) }
  let(:actor)    { create(:user, :super_admin, business: business) }

  subject(:result) { described_class.call(business: business, actor: actor) }

  context "when today matches the generate day" do
    it "succeeds" do
      expect(result.success?).to be true
    end

    it "creates a payroll period" do
      expect { result }.to change(PayrollPeriod, :count).by(1)
    end

    it "creates an audit log entry" do
      expect { result }.to change(PayrollAuditLog, :count).by(1)
    end

    it "sets auto: true metadata on the audit log" do
      result
      log = PayrollAuditLog.last
      expect(JSON.parse(log.metadata)["auto"]).to be true
    end
  end

  context "when auto_generate_day is nil (disabled)" do
    before { business.update_column(:payroll_auto_generate_day, nil) }

    it "skips generation" do
      expect(result.skipped?).to be true
    end

    it "does not create a period" do
      expect { result }.not_to change(PayrollPeriod, :count)
    end
  end

  context "when today does NOT match the generate day" do
    before { business.update_column(:payroll_auto_generate_day, (business_today.day % 28) + 1) }

    it "skips generation" do
      expect(result.skipped?).to be true
    end
  end

  context "when a finalized period already exists for this month" do
    before do
      create(:payroll_period, :finalized,
             business:     business,
             period_year:  business_today.year,
             period_month: business_today.month)
    end

    it "skips generation" do
      expect(result.skipped?).to be true
    end

    it "does not create a duplicate period" do
      expect { result }.not_to change(PayrollPeriod, :count)
    end
  end

  context "when a draft period exists for this month" do
    before do
      create(:payroll_period, :draft,
             business:     business,
             period_year:  business_today.year,
             period_month: business_today.month)
    end

    it "succeeds (regenerates the draft)" do
      expect(result.success?).to be true
    end

    it "does not create a duplicate period" do
      expect { result }.not_to change(PayrollPeriod, :count)
    end
  end
end
