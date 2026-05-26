require "rails_helper"

RSpec.describe Payroll::AutoGenerator do
  let(:business) { create(:business, payroll_auto_generate_day: Date.current.day) }
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
    before { business.update_column(:payroll_auto_generate_day, (Date.current.day % 28) + 1) }

    it "skips generation" do
      expect(result.skipped?).to be true
    end
  end

  context "when a finalized period already exists for this month" do
    before do
      create(:payroll_period, :finalized,
             business:     business,
             period_year:  Date.current.year,
             period_month: Date.current.month)
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
             period_year:  Date.current.year,
             period_month: Date.current.month)
    end

    it "succeeds (regenerates the draft)" do
      expect(result.success?).to be true
    end

    it "does not create a duplicate period" do
      expect { result }.not_to change(PayrollPeriod, :count)
    end
  end
end
