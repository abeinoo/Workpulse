require "rails_helper"
require "csv"

# Reporting of the manual-deduction waiver layer: original / waived / applied
# deductions in both the PayrollSummary aggregate and the CSV export.
RSpec.describe "Payroll deduction waiver reporting", type: :service do
  let(:business) { create(:business, currency: "SAR") }
  let(:period)   { create(:payroll_period, business: business) }
  let(:emp_a)    { create(:user, business: business) }
  let(:emp_b)    { create(:user, business: business) }

  # emp_a: a 100 manual deduction that has been waived → applied 0.
  let!(:entry_a) do
    create(:payroll_entry, payroll_period: period, user: emp_a,
           base_salary: 5_000.0, total_deductions: 0.0, net_salary: 5_000.0)
  end
  let!(:waived_ded) do
    create(:payroll_line_item, :manual_deduction, :deduction_waived,
           payroll_entry: entry_a, amount: -100.0)
  end

  # emp_b: a 60 manual deduction still active → applied 60.
  let!(:entry_b) do
    create(:payroll_entry, payroll_period: period, user: emp_b,
           base_salary: 3_000.0, total_deductions: 60.0, net_salary: 2_940.0)
  end
  let!(:active_ded) do
    create(:payroll_line_item, :manual_deduction, payroll_entry: entry_b, amount: -60.0)
  end

  describe Reports::PayrollSummary do
    subject(:result) { described_class.call(period: period) }

    it "reports original / waived / applied deduction totals" do
      totals = result[:totals]
      expect(totals[:original_deductions]).to eq(160.0)
      expect(totals[:waived_deductions]).to eq(100.0)
      expect(totals[:applied_deductions]).to eq(60.0)
    end

    it "reports per-employee waiver figures" do
      row_a = result[:entries].find { |e| e[:user_id] == emp_a.id }
      expect(row_a[:original_deductions]).to eq(100.0)
      expect(row_a[:waived_deductions]).to eq(100.0)
      expect(row_a[:applied_deductions]).to eq(0.0)
      expect(row_a[:any_deduction_waived]).to be true

      row_b = result[:entries].find { |e| e[:user_id] == emp_b.id }
      expect(row_b[:waived_deductions]).to eq(0.0)
      expect(row_b[:any_deduction_waived]).to be false
    end
  end

  describe Reports::PayrollCsvExporter do
    subject(:csv) { described_class.call(period: period, business: business) }

    it "includes the original / waived / applied deduction columns in the header" do
      header = CSV.parse(csv)[1]
      expect(header).to include("Original Deductions (SAR)", "Waived Deductions (SAR)", "Applied Deductions (SAR)")
    end

    it "includes the waived total in the TOTALS row" do
      totals = CSV.parse(csv).find { |r| r[1] == "TOTALS" }
      expect(totals).to include("100.0")
    end
  end
end
