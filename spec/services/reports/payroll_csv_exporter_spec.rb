require "rails_helper"
require "csv"

RSpec.describe Reports::PayrollCsvExporter, type: :service do
  let(:business) { create(:business, currency: "SAR") }
  let(:period)   { create(:payroll_period, business: business) }
  let(:emp_a)    { create(:user, business: business) }
  let(:emp_b)    { create(:user, business: business) }

  let!(:entry_a) do
    create(:payroll_entry, payroll_period: period, user: emp_a,
           base_salary: 5_000.0, net_salary: 4_800.0)
  end
  let!(:entry_b) do
    create(:payroll_entry, payroll_period: period, user: emp_b,
           base_salary: 3_000.0, net_salary: 2_900.0)
  end

  # Index 0 is user_id (integer string) — reliable way to isolate data rows.
  def data_rows(raw_csv)
    CSV.parse(raw_csv).select { |r| r[0].to_i > 0 }
  end

  def totals_row(raw_csv)
    CSV.parse(raw_csv).find { |r| r[1] == "TOTALS" }
  end

  describe "without entries: — full period export" do
    subject(:csv) { described_class.call(period: period, business: business) }

    it "contains one data row per employee" do
      expect(data_rows(csv).size).to eq(2)
    end

    it "includes both employees by name" do
      names = data_rows(csv).map { |r| r[1] }
      expect(names).to include(emp_a.full_name, emp_b.full_name)
    end

    it "TOTALS row base_salary is the full business sum" do
      expect(totals_row(csv)[3].to_f).to eq(8_000.0)
    end

    it "TOTALS row net_salary is the full business sum" do
      expect(totals_row(csv)[12].to_f).to eq(7_700.0)
    end

    it "includes a currency header row" do
      rows = CSV.parse(csv)
      expect(rows.first[0]).to eq("Currency: SAR")
    end
  end

  describe "with entries: — scoped to one employee (branch manager path)" do
    subject(:csv) { described_class.call(period: period, business: business, entries: scoped) }

    let(:scoped) { PayrollEntry.where(id: entry_a.id) }

    it "contains exactly one data row" do
      expect(data_rows(csv).size).to eq(1)
    end

    it "that row belongs to the scoped employee" do
      expect(data_rows(csv).first[1]).to eq(emp_a.full_name)
    end

    it "does not include the out-of-scope employee" do
      names = data_rows(csv).map { |r| r[1] }
      expect(names).not_to include(emp_b.full_name)
    end

    it "TOTALS row reflects only the scoped employee's salary" do
      expect(totals_row(csv)[3].to_f).to eq(5_000.0)
    end

    it "TOTALS row never contains the out-of-scope employee's salary" do
      expect(totals_row(csv)[3].to_f).not_to eq(8_000.0)
    end
  end

  describe "cross-scope partition invariant" do
    it "branch A totals + branch B totals equal the unscoped total" do
      full  = totals_row(described_class.call(period: period, business: business))[3].to_f
      part_a = totals_row(described_class.call(period: period, business: business,
                                               entries: PayrollEntry.where(id: entry_a.id)))[3].to_f
      part_b = totals_row(described_class.call(period: period, business: business,
                                               entries: PayrollEntry.where(id: entry_b.id)))[3].to_f
      expect(part_a + part_b).to eq(full)
    end
  end
end
