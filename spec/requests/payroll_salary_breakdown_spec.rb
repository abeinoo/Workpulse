require "rails_helper"
require "csv"

# The persisted basic salary breakdown (PayrollEntry#salary_breakdown) is shown
# on the payroll entry page only; the payroll API and CSV contracts are unchanged
# (both list their fields explicitly — the new column is not exposed there).
RSpec.describe "Payroll salary breakdown surfaces", type: :request do
  let(:business) { create(:business, currency: "EGP") }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:period)   { create(:payroll_period, business: business, period_year: 2026, period_month: 10) }

  let(:split_breakdown) do
    { "version" => 1, "period_calendar_days" => 31, "total" => "10645.16",
      "portions" => [
        { "salary_profile_id" => 1, "salary_type" => "monthly", "base_amount" => "9000.00",
          "starts_on" => "2026-10-01", "ends_on" => "2026-10-14", "calendar_days" => 14,
          "days_worked" => 10, "amount" => "4064.52" },
        { "salary_profile_id" => 2, "salary_type" => "daily", "base_amount" => "500.00",
          "starts_on" => "2026-10-15", "ends_on" => "2026-10-31", "calendar_days" => 17,
          "days_worked" => 8, "amount" => "6580.64" }
      ] }
  end
  let!(:entry) do
    create(:payroll_entry, payroll_period: period, user: employee, salary_type: "daily",
                           base_salary: 10_645.16, net_salary: 10_645.16, salary_breakdown: split_breakdown)
  end

  before { sign_in owner }

  it "keeps the API entry fields exactly as before" do
    get "/api/v1/payroll_periods/#{period.id}/payroll_entries", as: :json

    row = response.parsed_body["data"].find { |e| e["id"] == entry.id }
    expect(row).not_to have_key("salary_breakdown")
    expect(row.keys).to match_array(%w[
      id user_id salary_type base_salary working_days days_worked total_deductions total_overtime
      total_bonuses already_paid_total advances_deducted obligations_deducted net_salary status notes
      payroll_period_id gross_salary total_adjustments currency
    ])
  end

  it "keeps the CSV columns exactly as before, base salary as the single figure" do
    csv  = Reports::PayrollCsvExporter.call(period: period, business: business)
    rows = CSV.parse(csv)

    header = rows.find { |r| r[0] == "Employee ID" }
    expect(header).to eq([
      "Employee ID", "Full Name", "Salary Type", "Base Salary (EGP)", "Working Days", "Days Worked",
      "Total Deductions (EGP)", "Original Deductions (EGP)", "Waived Deductions (EGP)", "Applied Deductions (EGP)",
      "Calculated Overtime (EGP)", "Approved Overtime (EGP)", "Overtime Difference (EGP)",
      "Total Bonuses (EGP)", "Paid During Period (EGP)", "Advances Deducted (EGP)", "Obligations Deducted (EGP)",
      "Final Payable (EGP)", "Status"
    ])
    data = rows.find { |r| r[0] == employee.id.to_s }
    expect(data[2]).to eq("daily")
    expect(data[3].to_f).to eq(10_645.16)
  end

  it "counts base salary once in the period financial summary" do
    summary = Payroll::PeriodFinancialSummary.new(period.payroll_entries)
    expect(summary.gross_payroll).to eq(10_645.16)
  end

  it "shows each portion under the base salary on the payroll entry page" do
    get payroll_period_payroll_entry_path(period, entry)

    expect(response).to have_http_status(:ok)
    page = response.body
    expect(page).to include(I18n.t("payroll.entry.salary_portions_header"))
    expect(page).to include("4,064.52").and include("6,580.64")
    expect(page).to include("14 of 31 days")
    expect(page).to include("8 day(s) worked")
  end

  it "describes a starter's monthly portions by their share of the starter's working days" do
    entry.update!(salary_breakdown: split_breakdown.merge(
      "proration" => "starter_working_days", "salary_window_days" => 16, "starter_working_days" => 13,
      "portions" => split_breakdown["portions"].map { |p| p.merge("salary_type" => "monthly", "calendar_days" => 8) }
    ))
    get payroll_period_payroll_entry_path(period, entry)

    expect(response.body).to include("8 of 16 days of a 13-working-day start")
    expect(response.body).not_to include("of 31 days")
  end

  it "shows no portions for an entry built from a single profile or calculated before the breakdown" do
    entry.update!(salary_breakdown: split_breakdown.merge("portions" => split_breakdown["portions"].first(1)))
    get payroll_period_payroll_entry_path(period, entry)
    expect(response.body).not_to include(I18n.t("payroll.entry.salary_portions_header"))

    entry.update!(salary_breakdown: nil)
    get payroll_period_payroll_entry_path(period, entry)
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(I18n.t("payroll.entry.salary_portions_header"))
  end
end
