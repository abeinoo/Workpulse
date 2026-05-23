require "rails_helper"

RSpec.describe Reports::PayrollSummary, type: :service do
  let(:business) { create(:business) }
  let(:period)   { create(:payroll_period, business: business) }
  let(:emp_a)    { create(:user, business: business) }
  let(:emp_b)    { create(:user, business: business) }

  let!(:entry_a) do
    create(:payroll_entry, payroll_period: period, user: emp_a,
           base_salary: 5_000.0, total_deductions: 200.0, net_salary: 4_800.0)
  end
  let!(:entry_b) do
    create(:payroll_entry, payroll_period: period, user: emp_b,
           base_salary: 3_000.0, total_deductions: 100.0, net_salary: 2_900.0)
  end

  describe ".call without entries: — full period (owner / admin path)" do
    subject(:result) { described_class.call(period: period) }

    it "returns rows for every employee in the period" do
      user_ids = result[:entries].map { |e| e[:user_id] }
      expect(user_ids).to contain_exactly(emp_a.id, emp_b.id)
    end

    it "totals reflect all entries" do
      expect(result[:totals][:employees]).to eq(2)
      expect(result[:totals][:base_salary]).to eq(8_000.0)
      expect(result[:totals][:net_salary]).to eq(7_700.0)
    end

    it "includes period metadata" do
      expect(result[:period_id]).to eq(period.id)
      expect(result[:status]).to eq(period.status)
      expect(result[:working_days]).to eq(period.working_days)
    end

    it "does not include entries from a different period" do
      other_entry = create(:payroll_entry)
      user_ids = result[:entries].map { |e| e[:user_id] }
      expect(user_ids).not_to include(other_entry.user_id)
    end
  end

  describe ".call with entries: — pre-scoped relation (manager path)" do
    subject(:result) { described_class.call(period: period, entries: scoped) }

    let(:scoped) { PayrollEntry.where(id: entry_a.id) }

    it "returns rows only for the employees in the scoped relation" do
      user_ids = result[:entries].map { |e| e[:user_id] }
      expect(user_ids).to contain_exactly(emp_a.id)
    end

    it "excludes out-of-scope employees entirely" do
      user_ids = result[:entries].map { |e| e[:user_id] }
      expect(user_ids).not_to include(emp_b.id)
    end

    it "totals reflect only the scoped entries — not the full business total" do
      expect(result[:totals][:employees]).to eq(1)
      expect(result[:totals][:base_salary]).to eq(5_000.0)
      expect(result[:totals][:net_salary]).to eq(4_800.0)
    end

    it "totals never bleed in the other employee's salary" do
      expect(result[:totals][:base_salary]).not_to eq(8_000.0)
    end

    it "still returns correct period metadata regardless of scoping" do
      expect(result[:period_id]).to eq(period.id)
    end
  end

  describe "entry row structure" do
    subject(:row) { described_class.call(period: period)[:entries].first }

    it "includes all expected keys" do
      expect(row.keys).to include(
        :user_id, :full_name, :salary_type,
        :base_salary, :working_days, :days_worked,
        :total_deductions, :total_overtime, :total_bonuses,
        :already_paid_total, :advances_deducted, :obligations_deducted,
        :net_salary, :status
      )
    end

    it "full_name is a non-blank string" do
      expect(row[:full_name]).to be_a(String).and(be_present)
    end
  end

  describe "partition invariant" do
    it "scoped-A totals + scoped-B totals equal the unscoped total" do
      total_full = described_class.call(period: period)[:totals][:base_salary]
      total_a    = described_class.call(period: period, entries: PayrollEntry.where(id: entry_a.id))[:totals][:base_salary]
      total_b    = described_class.call(period: period, entries: PayrollEntry.where(id: entry_b.id))[:totals][:base_salary]
      expect(total_a + total_b).to eq(total_full)
    end
  end
end
