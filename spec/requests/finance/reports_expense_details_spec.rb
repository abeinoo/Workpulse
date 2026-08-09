require "rails_helper"

RSpec.describe "Finance::Reports expense details", type: :request do
  let(:business) { create(:business) }
  let(:branch_a) { create(:branch, business: business, name: "Branch A") }
  let(:branch_b) { create(:branch, business: business, name: "Branch B") }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:month)    { Date.current.beginning_of_month }
  let(:employee) { create(:user, business: business, first_name: "Sara", last_name: "Ali") }

  before do
    period = create(:payroll_period, business: business, period_year: month.year, period_month: month.month)
    create(:payroll_entry, payroll_period: period, user: employee, base_salary: 4000, total_overtime: 0, total_bonuses: 0, net_salary: 4000)
    create(:shift_assignment, user: employee, branch: branch_a, effective_from: month - 1.month, effective_to: nil)

    create(:expense, :approved, business: business, branch: branch_a, amount: 300, expense_date: month + 5.days)

    sign_in owner
  end

  it "renders the report with KPI sections and per-branch payroll detail" do
    get finance_expense_details_report_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("finance.reports.expense_details.title"))
    expect(response.body).to include("Branch A")
  end

  it "preserves filter params (month/year/branch_id/expense_type_id)" do
    get finance_expense_details_report_path(branch_id: branch_a.id, month: month.month, year: month.year)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("branch_id=#{branch_a.id}")
  end

  it "redirects a user without view_expense_reports" do
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: [ "view_expenses" ])
    viewer = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
    sign_in viewer

    get finance_expense_details_report_path
    expect(response).to redirect_to(finance_root_path)
  end

  it "exports a CSV containing hierarchy-level detail, not just totals" do
    get finance_expense_details_report_path(format: :csv)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(employee.full_name)
    expect(response.media_type).to eq("text/csv")
  end

  describe "sales-branch scoping" do
    let!(:laundry) { create(:branch, business: business, name: "Laundry Branch", branch_type: "laundry") }
    let!(:branch_b_present) { branch_b }

    it "only lists sales branches in the branch selector" do
      get finance_expense_details_report_path

      options = Nokogiri::HTML(response.body).css("select[name='branch_id'] option").map(&:text)
      expect(options).to include("Branch A", "Branch B")
      expect(options).not_to include("Laundry Branch")
    end

    it "All Branches means all sales branches only (never includes Laundry)" do
      get finance_expense_details_report_path

      options = Nokogiri::HTML(response.body).css("select[name='branch_id'] option")
      expect(options.first.text).to eq(I18n.t("finance.reports.profitability_dashboard.all_branches"))
      expect(options.map(&:text)).to contain_exactly(
        I18n.t("finance.reports.profitability_dashboard.all_branches"), "Branch A", "Branch B"
      )
    end
  end

  describe "period filter — presets" do
    it "backward compatible: only month/year (no period_type) still resolves a single month exactly as before" do
      get finance_expense_details_report_path(month: month.month, year: month.year)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.l(month, format: "%B %Y"))
    end

    it "last_3_months shows the 3-month range label and includes the 2-months-ago period's own data" do
      older_month = (month - 2.months)
      older_period = create(:payroll_period, business: business, period_year: older_month.year, period_month: older_month.month)
      older_employee = create(:user, business: business)
      create(:payroll_entry, payroll_period: older_period, user: older_employee, base_salary: 900, total_overtime: 0, total_bonuses: 0, net_salary: 900)
      create(:shift_assignment, user: older_employee, branch: branch_a, effective_from: older_month - 1.month, effective_to: nil)

      get finance_expense_details_report_path(period_type: "last_3_months", month: month.month, year: month.year)

      expect(response).to have_http_status(:ok)
      from_label = I18n.l(older_month.beginning_of_month, format: "%B %Y")
      to_label   = I18n.l(month, format: "%B %Y")
      expect(response.body).to include("#{from_label} → #{to_label}")
      expect(response.body).to include(older_employee.full_name)
    end

    it "last_6_months and last_12_months render without error" do
      get finance_expense_details_report_path(period_type: "last_6_months", month: month.month, year: month.year)
      expect(response).to have_http_status(:ok)

      get finance_expense_details_report_path(period_type: "last_12_months", month: month.month, year: month.year)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "period filter — custom range" do
    it "renders a valid custom range with a from → to label" do
      from = month - 2.months
      get finance_expense_details_report_path(period_type: "custom",
        from_year: from.year, from_month: from.month, to_year: month.year, to_month: month.month)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("#{I18n.l(from, format: '%B %Y')} → #{I18n.l(month, format: '%B %Y')}")
    end

    it "shows a clear Arabic validation message and falls back safely for an inverted range" do
      later = month + 2.months
      get finance_expense_details_report_path(period_type: "custom",
        from_year: later.year, from_month: later.month, to_year: month.year, to_month: month.month)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("finance.reports.expense_details.period.invalid_range"))
    end
  end

  describe "reset and active filter summary" do
    it "reset link points to the bare report path (current month, all branches, all types)" do
      get finance_expense_details_report_path(branch_id: branch_a.id, period_type: "last_3_months")

      reset_link = Nokogiri::HTML(response.body).css("a").find { |a| a.text.strip == I18n.t("finance.reports.expense_details.filters.reset") }
      expect(reset_link["href"]).to eq(finance_expense_details_report_path)
    end

    it "shows no active-filter summary for default filters (current month, all branches, all types)" do
      get finance_expense_details_report_path
      expect(response.body).not_to include(I18n.t("finance.reports.expense_details.filters.active_summary"))
    end

    it "shows the active-filter summary with period/branch/section chips and a clear-all action when filters are non-default" do
      get finance_expense_details_report_path(branch_id: branch_a.id, section: "payroll", period_type: "last_3_months")

      expect(response.body).to include(I18n.t("finance.reports.expense_details.filters.active_summary"))
      expect(response.body).to include("Branch A")
      expect(response.body).to include(I18n.t("finance.reports.expense_details.sections.payroll"))
      expect(response.body).to include(I18n.t("finance.reports.expense_details.filters.clear_all"))
    end
  end

  describe "expense type (section) filter" do
    it "narrows the page to only the selected section without altering the underlying totals" do
      get finance_expense_details_report_path(section: "payroll")
      expect(response).to have_http_status(:ok)

      body = Nokogiri::HTML(response.body)
      section_titles = body.css(".section-title--exec").map { |el| el.text.strip }
      expect(section_titles.any? { |t| t.include?(I18n.t("finance.reports.expense_details.sections.payroll")) }).to be true
      expect(section_titles.any? { |t| t.include?(I18n.t("finance.reports.expense_details.sections.inventory")) }).to be false
    end

    it "an unrecognized section value is ignored (shows all sections, same as no filter)" do
      get finance_expense_details_report_path(section: "not_a_real_section")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("finance.reports.expense_details.sections.inventory"))
    end
  end

  describe "no double counting across a multi-month + branch-filtered view" do
    it "reconciles against the sum of Branch Profitability's totals for the same range" do
      get finance_expense_details_report_path(period_type: "last_3_months", branch_id: branch_a.id, month: month.month, year: month.year)
      expect(response).to have_http_status(:ok)

      period = Finance::Reports::PeriodResolver.call(period_type: "last_3_months", month: month.month.to_s, year: month.year.to_s)
      result = Finance::Reports::ExpenseDetails.new(business, year: period.from_year, month: period.from_month,
                                                     to_year: period.to_year, to_month: period.to_month, branch_id: branch_a.id).call
      expect(result.reconciliation).to be_matches
    end
  end
end
