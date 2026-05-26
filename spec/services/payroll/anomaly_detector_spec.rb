require "rails_helper"

RSpec.describe Payroll::AnomalyDetector do
  let(:business) { create(:business) }
  let(:period) do
    create(:payroll_period, business: business, period_year: 2026, period_month: 5)
  end

  let(:user1) { create(:user, business: business) }
  let(:user2) { create(:user, business: business) }

  def build_entry(user:, days_worked: 20, working_days: 22,
                  net_salary: 5000, base_salary: 5000,
                  total_overtime: 0, total_deductions: 0)
    build_stubbed(:payroll_entry,
      payroll_period: period,
      user:           user,
      days_worked:    days_worked,
      working_days:   working_days,
      net_salary:     net_salary,
      base_salary:    base_salary,
      total_overtime: total_overtime,
      total_deductions: total_deductions
    )
  end

  subject(:detector) { described_class.new(period: period, entries: entries) }

  context "with clean entries" do
    let(:entries) { [ build_entry(user: user1), build_entry(user: user2) ] }

    it "returns no anomalies" do
      expect(detector.detect).to be_empty
    end
  end

  describe "negative net salary" do
    let(:entries) { [ build_entry(user: user1, net_salary: -200) ] }

    it "returns a danger anomaly" do
      anomalies = detector.detect
      danger = anomalies.find { |a| a.code == :negative_net }
      expect(danger).not_to be_nil
      expect(danger.severity).to eq(:danger)
      expect(danger.affected).to include(entries.first)
    end
  end

  describe "paid zero attendance" do
    let(:entries) { [ build_entry(user: user1, days_worked: 0, net_salary: 3000) ] }

    it "returns a danger anomaly (paid despite no attendance)" do
      anomalies = detector.detect
      a = anomalies.find { |x| x.code == :paid_zero_attendance }
      expect(a).not_to be_nil
      expect(a.severity).to eq(:danger)
    end
  end

  describe "unpaid zero attendance" do
    let(:entries) { [ build_entry(user: user1, days_worked: 0, net_salary: 0) ] }

    it "returns a warning anomaly" do
      anomalies = detector.detect
      a = anomalies.find { |x| x.code == :zero_attendance }
      expect(a).not_to be_nil
      expect(a.severity).to eq(:warning)
    end
  end

  describe "abnormal overtime" do
    let(:entries) do
      [ build_entry(user: user1, base_salary: 5000, total_overtime: 2000) ]
    end

    it "returns a warning when overtime exceeds 30% of base" do
      anomalies = detector.detect
      a = anomalies.find { |x| x.code == :abnormal_overtime }
      expect(a).not_to be_nil
      expect(a.severity).to eq(:warning)
    end

    it "does not fire when overtime is within threshold" do
      entries_ok = [ build_entry(user: user1, base_salary: 5000, total_overtime: 1000) ]
      det = described_class.new(period: period, entries: entries_ok)
      expect(det.detect.map(&:code)).not_to include(:abnormal_overtime)
    end
  end

  describe "high deductions" do
    let(:entries) do
      [ build_entry(user: user1, base_salary: 5000, total_deductions: 2500) ]
    end

    it "returns a warning when deductions exceed 40% of base" do
      a = detector.detect.find { |x| x.code == :high_deductions }
      expect(a).not_to be_nil
      expect(a.severity).to eq(:warning)
    end
  end

  describe "pending items" do
    let(:entries) { [ build_entry(user: user1) ] }
    subject(:detector) do
      described_class.new(period: period, entries: entries, pending_count: 3)
    end

    it "returns a warning for pending review items" do
      a = detector.detect.find { |x| x.code == :pending_items }
      expect(a).not_to be_nil
      expect(a.severity).to eq(:warning)
    end
  end

  describe "sorting" do
    let(:entries) do
      [
        build_entry(user: user1, days_worked: 0, net_salary: 0),   # warning
        build_entry(user: user2, net_salary: -100)                 # danger
      ]
    end

    it "returns danger anomalies before warnings" do
      anomalies = detector.detect
      severities = anomalies.map(&:severity)
      danger_idx  = severities.index(:danger)
      warning_idx = severities.index(:warning)
      expect(danger_idx).to be < warning_idx
    end
  end
end
