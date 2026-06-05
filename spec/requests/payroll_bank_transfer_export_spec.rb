require "rails_helper"
require "csv"

RSpec.describe "Payroll bank transfer export", type: :request do
  let(:business)   { create(:business) }
  let(:accountant) { create(:user, :accountant, business: business) }
  let(:employee)   { create(:user, business: business) }

  let(:period) { create(:payroll_period, :finalized, business: business, period_year: 2026, period_month: 4) }

  let(:emp_a) { create(:user, business: business, employee_code: "1001", identity_card_number: "29801011234567") }
  let(:emp_b) { create(:user, business: business, employee_code: "1002", identity_card_number: nil) }

  let!(:entry_a) { create(:payroll_entry, :approved, payroll_period: period, user: emp_a, net_salary: 8_500.0) }
  let!(:entry_b) { create(:payroll_entry, :approved, payroll_period: period, user: emp_b, net_salary: 7_200.0) }

  describe "GET /payroll_periods/:id/export_bank_transfer" do
    it "streams the CSV with the period-stamped filename for a payroll viewer" do
      sign_in accountant
      get export_bank_transfer_payroll_period_path(period)

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/csv")
      expect(response.headers["Content-Disposition"])
        .to include("payroll_bank_transfer_2026_04.csv")
    end

    it "contains the eligible employees with the missing-ID flag" do
      sign_in accountant
      get export_bank_transfer_payroll_period_path(period)

      rows = CSV.parse(response.body)
      expect(rows.first).to eq(["Employee Code", "Employee Name", "National ID", "Net Salary", "Issues"])

      flagged = rows.find { |r| r[0] == "1002" }
      expect(flagged[4]).to eq("Missing National ID")
    end

    it "denies a non-payroll user" do
      sign_in employee
      get export_bank_transfer_payroll_period_path(period)

      expect(response).not_to have_http_status(:ok)
    end

    it "is unavailable while the period is still draft" do
      draft = create(:payroll_period, business: business, period_year: 2026, period_month: 5)
      sign_in accountant
      get export_bank_transfer_payroll_period_path(draft)

      expect(response).not_to have_http_status(:ok)
    end
  end

  describe "GET /payroll_periods/:id (summary banner)" do
    it "shows the bank transfer summary figures on a finalized period" do
      sign_in accountant
      get payroll_period_path(period)

      expect(response.body).to include(I18n.t("payroll.bank_transfer.banner_title"))
      expect(response.body).to include(I18n.t("payroll.bank_transfer.export"))
      # 2 eligible employees, 1 missing a national id.
      expect(response.body).to include(I18n.t("payroll.bank_transfer.total_employees"))
      expect(response.body).to include(I18n.t("payroll.bank_transfer.missing_national_id"))
    end
  end
end
