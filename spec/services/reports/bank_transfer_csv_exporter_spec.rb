require "rails_helper"
require "csv"

RSpec.describe Reports::BankTransferCsvExporter, type: :service do
  let(:business) { create(:business) }
  let(:period)   { create(:payroll_period, :finalized, business: business, period_year: 2026, period_month: 4) }

  let(:emp_a) { create(:user, business: business, employee_code: "1001", identity_card_number: "29801011234567") }
  let(:emp_b) { create(:user, business: business, employee_code: "1002", identity_card_number: nil) }

  let!(:entry_a) do
    create(:payroll_entry, :approved, payroll_period: period, user: emp_a, net_salary: 8_500.0)
  end
  let!(:entry_b) do
    create(:payroll_entry, :approved, payroll_period: period, user: emp_b, net_salary: 7_200.0)
  end

  subject(:exporter) { described_class.new(period: period) }

  def parsed(csv) = CSV.parse(csv)
  def data_rows(csv) = parsed(csv)[1..] # drop the header row

  describe "#to_csv" do
    it "uses the exact required header columns" do
      expect(parsed(exporter.to_csv).first)
        .to eq(["Employee Code", "Employee Name", "National ID", "Net Salary", "Issues"])
    end

    it "exports one row per eligible employee, ordered by employee code" do
      codes = data_rows(exporter.to_csv).map { |r| r[0] }
      expect(codes).to eq(%w[1001 1002])
    end

    it "writes employee code, name, national id and net salary" do
      row = data_rows(exporter.to_csv).first
      expect(row[0]).to eq("1001")
      expect(row[1]).to eq(emp_a.full_name)
      expect(row[2]).to eq("29801011234567")
      expect(row[3].to_f).to eq(8_500.0)
    end

    it "leaves the Issues column blank when the national id is present" do
      expect(data_rows(exporter.to_csv).first[4]).to be_nil
    end

    it "flags a missing national id but still exports the row" do
      row = data_rows(exporter.to_csv).find { |r| r[0] == "1002" }
      expect(row[2]).to be_nil
      expect(row[4]).to eq("Missing National ID")
    end

    context "validation / exclusions" do
      it "excludes employees with net salary <= 0" do
        create(:user, business: business, employee_code: "1003", identity_card_number: "30001019999999").tap do |u|
          create(:payroll_entry, :approved, payroll_period: period, user: u, net_salary: 0.0)
        end
        create(:user, business: business, employee_code: "1004", identity_card_number: "30001018888888").tap do |u|
          create(:payroll_entry, :approved, payroll_period: period, user: u, net_salary: -50.0)
        end

        codes = data_rows(exporter.to_csv).map { |r| r[0] }
        expect(codes).to contain_exactly("1001", "1002")
      end

      it "excludes inactive (disputed) payroll entries" do
        disputed_emp = create(:user, business: business, employee_code: "1005", identity_card_number: "30001017777777")
        create(:payroll_entry, payroll_period: period, user: disputed_emp, net_salary: 4_000.0, status: :disputed)

        codes = data_rows(exporter.to_csv).map { |r| r[0] }
        expect(codes).not_to include("1005")
      end
    end

    context "with a scoped entries relation" do
      subject(:exporter) { described_class.new(period: period, entries: PayrollEntry.where(id: entry_a.id)) }

      it "only exports the scoped employees" do
        codes = data_rows(exporter.to_csv).map { |r| r[0] }
        expect(codes).to eq(%w[1001])
      end
    end
  end

  describe "#summary" do
    it "counts only eligible employees" do
      expect(exporter.summary[:total_employees]).to eq(2)
    end

    it "totals the net salary of eligible employees" do
      expect(exporter.summary[:total_amount]).to eq(15_700.0)
    end

    it "counts employees missing a national id" do
      expect(exporter.summary[:missing_national_id]).to eq(1)
    end

    it "ignores excluded entries in every figure" do
      ineligible = create(:user, business: business, employee_code: "1009", identity_card_number: nil)
      create(:payroll_entry, :approved, payroll_period: period, user: ineligible, net_salary: 0.0)

      expect(exporter.summary).to eq(total_employees: 2, total_amount: 15_700.0, missing_national_id: 1)
    end
  end

  describe "#filename" do
    it "is zero-padded as payroll_bank_transfer_YYYY_MM.csv" do
      expect(exporter.filename).to eq("payroll_bank_transfer_2026_04.csv")
    end
  end
end
