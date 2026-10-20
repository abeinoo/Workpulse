require "rails_helper"
require "csv"

# Payroll cost in Finance reports and the Finance dashboard (decision of
# 2026-10-19, Finance::PayrollCostAccess):
# * without view_payroll — no payroll cost, and nothing it can be recovered
#   from (net profit, margin, a total including it, chart series, insights) —
#   in HTML, CSV, chart data and the PDF export;
# * with view_payroll — only for the branches of its scope (BranchScope:
#   configured, else managed + area-managed; every branch for the owner); a
#   total or net that would include another branch's payroll is withheld;
# * request parameters (branch_id) never widen it; other businesses never;
# * everything else (revenue, expenses, inventory) is unchanged, and the
#   figures shown are exactly the unrestricted ones.
RSpec.describe "Finance payroll cost visibility", type: :request do
  let(:business) { create(:business) }
  let(:branch_a) { create(:branch, business: business, name: "Alpha Branch") }
  let(:branch_b) { create(:branch, business: business, name: "Bravo Branch") }
  let(:month)    { Date.current.prev_month.beginning_of_month }
  let!(:owner)   { create(:user, :owner, business: business) }

  let(:emp_a) { employee_at(branch_a, "Aaron Alpha") }
  let(:emp_b) { employee_at(branch_b, "Bella Bravo") }

  # Gross payroll: A 7,111.11 · B 8,222.22 (total 15,333.33). Branch A also has
  # a 333.33 expense, so A's net is −7,444.44 and the total net −15,666.66.
  let!(:period) do
    create(:payroll_period, :finalized, business: business, period_year: month.year, period_month: month.month).tap do |p|
      create(:payroll_entry, payroll_period: p, user: emp_a, base_salary: 7_111.11, net_salary: 7_000)
      create(:payroll_entry, payroll_period: p, user: emp_b, base_salary: 8_222.22, net_salary: 8_000)
    end
  end
  let!(:expense) do
    create(:expense, :approved, business: business, branch: branch_a, amount: 333.33, expense_date: month + 3.days)
  end

  A_PAYROLL = %w[7111.11 7,111.11 7444.44 7,444.44].freeze
  B_PAYROLL = %w[8222.22 8,222.22].freeze
  TOTALS    = %w[15333.33 15,333.33 15666.66 15,666.66].freeze

  def employee_at(branch, name)
    first, last = name.split
    create(:user, business: business, first_name: first, last_name: last).tap do |u|
      create(:shift_assignment, business: business, user: u, branch: branch,
                                effective_from: month - 1.month, effective_to: nil)
    end
  end

  def role_user(*permissions, scopes: {}, in_business: business)
    role = in_business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: permissions.map(&:to_s),
                                                permission_scopes: scopes)
    create(:user, business: in_business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  # Manages Alpha and area-manages Bravo — both in the Finance branch scope.
  def manager_of_both(*permissions, scopes: {})
    role_user(*permissions, scopes: scopes).tap do |u|
      branch_a.update_column(:branch_manager_id, u.id)
      branch_b.update_column(:area_manager_id, u.id)
    end
  end

  def report_params = { year: month.year, month: month.month }
  def body_has_none_of(*groups) = groups.flatten.each { |s| expect(response.body).not_to include(s) }
  def body_has_all_of(*groups)  = groups.flatten.each { |s| expect(response.body).to include(s) }

  def profitability(format: nil, **extra)
    get finance_branch_profitability_report_path(report_params.merge(extra).merge(format ? { format: format } : {}))
    expect(response).to have_http_status(:ok)
  end

  def expense_details(format: nil, **extra)
    get finance_expense_details_report_path(report_params.merge(extra).merge(format ? { format: format } : {}))
    expect(response).to have_http_status(:ok)
  end

  describe "Branch Profitability (HTML, CSV)" do
    it "without view_payroll: no payroll, net or totals including them; revenue and expenses stay" do
      sign_in role_user(:view_expense_reports)

      profitability
      body_has_none_of(A_PAYROLL, B_PAYROLL, TOTALS)
      body_has_all_of("333.33", I18n.t("finance.reports.payroll_restricted_note"))

      profitability(format: :csv)
      body_has_none_of(A_PAYROLL, B_PAYROLL, TOTALS)
      expect(response.body).to include("333.33")
    end

    it "with view_payroll scoped to Alpha: Alpha's payroll and net only, no totals" do
      sign_in role_user(:view_expense_reports, :view_payroll).tap { |u| branch_a.update_column(:branch_manager_id, u.id) }

      profitability
      body_has_all_of("7,111.11", "7,444.44")
      body_has_none_of(B_PAYROLL, TOTALS)

      profitability(format: :csv)
      csv = CSV.parse(response.body.delete_prefix(Finance::Reports::CsvExporter::BOM))
      alpha = csv.find { |r| r.first == "Alpha Branch" }
      bravo = csv.find { |r| r.first == "Bravo Branch" }
      expect(alpha).to include("7111.11", "-7444.44")
      expect(bravo.compact).not_to include("8222.22", "-8222.22")
      body_has_none_of(B_PAYROLL, TOTALS)
    end

    it "a branch_id parameter does not widen it" do
      sign_in role_user(:view_expense_reports, :view_payroll).tap { |u| branch_a.update_column(:branch_manager_id, u.id) }

      profitability(branch_id: branch_b.id)
      body_has_none_of(B_PAYROLL, TOTALS)
    end

    it "with a business-wide view_payroll scope: every figure, identical to the unrestricted report" do
      sign_in role_user(:view_expense_reports, :view_payroll, scopes: { "view_payroll" => "business" })
      profitability(format: :csv)

      body_has_all_of("7111.11", "8222.22", "15333.33", "-15666.66")
      unrestricted = Finance::Reports::BranchProfitability.new(business, year: month.year, month: month.month).call
      expect(unrestricted.totals).to include(payroll: BigDecimal("15333.33"), net: BigDecimal("-15666.66"))
    end

    it "the owner sees every figure" do
      sign_in owner
      profitability
      body_has_all_of("7,111.11", "8,222.22", "15,333.33")
    end

    it "never shows another business's payroll" do
      sign_in role_user(:view_expense_reports, :view_payroll, scopes: { "view_payroll" => "business" },
                        in_business: create(:business))
      profitability(branch_id: branch_a.id)
      body_has_none_of(A_PAYROLL, B_PAYROLL, TOTALS)
    end
  end

  describe "Expense details (HTML, CSV)" do
    it "without view_payroll: no payroll section, no employee, totals exclude payroll" do
      sign_in role_user(:view_expense_reports)

      expense_details
      body_has_none_of(A_PAYROLL, B_PAYROLL, TOTALS, "Aaron Alpha", "Bella Bravo")
      body_has_all_of("333.33", I18n.t("finance.reports.payroll_restricted_note"))

      expense_details(format: :csv)
      body_has_none_of(A_PAYROLL, B_PAYROLL, TOTALS, "Aaron Alpha", "Bella Bravo")
      expect(response.body).to include("333.33")
    end

    it "with view_payroll scoped to Alpha: only Alpha's payroll group, also under a Bravo branch filter" do
      viewer = role_user(:view_expense_reports, :view_payroll).tap { |u| branch_a.update_column(:branch_manager_id, u.id) }
      sign_in viewer

      expense_details
      body_has_all_of("7,111.11", "Aaron Alpha")
      body_has_none_of(B_PAYROLL, TOTALS, "Bella Bravo")

      expense_details(branch_id: branch_b.id)
      body_has_none_of(B_PAYROLL, "Bella Bravo")
    end

    it "with a business-wide scope: the full report, reconciling with Branch Profitability" do
      sign_in role_user(:view_expense_reports, :view_payroll, scopes: { "view_payroll" => "business" })
      expense_details

      body_has_all_of("7,111.11", "8,222.22", "Aaron Alpha", "Bella Bravo")
      expect(response.body).not_to include(I18n.t("finance.reports.payroll_restricted_note"))
      result = Finance::Reports::ExpenseDetails.new(business, year: month.year, month: month.month).call
      expect(result.reconciliation).to be_matches
    end
  end

  describe "Finance dashboard (HTML, PDF)" do
    let(:dashboard_params) { { from: month.iso8601, to: month.end_of_month.iso8601 } }
    let(:net_label) { I18n.t("finance.dashboard.kpi.net_profit") }

    def dashboard
      get finance_root_path(dashboard_params)
      expect(response).to have_http_status(:ok)
    end

    def dashboard_pdf
      allow(Finance::Dashboard::PdfRenderer).to receive(:render) { |html| html }
      get finance_dashboard_export_pdf_path(dashboard_params)
      expect(response).to have_http_status(:ok)
    end

    it "without view_payroll: no net profit, margin or payroll anywhere; expenses stay" do
      sign_in manager_of_both(:view_finance_dashboard, :view_expense_reports)

      dashboard
      body_has_none_of(A_PAYROLL, B_PAYROLL, TOTALS, net_label, I18n.t("finance.dashboard.kpi.profit_margin"))
      dashboard_pdf
      body_has_none_of(A_PAYROLL, B_PAYROLL, TOTALS, net_label)
    end

    it "with view_payroll for only one of the branches in view: still no net profit" do
      sign_in manager_of_both(:view_finance_dashboard, :view_expense_reports, :view_payroll,
                              scopes: { "view_payroll" => "branch" })
      dashboard
      body_has_none_of(B_PAYROLL, TOTALS, net_label)
    end

    it "with view_payroll for every branch in view: net profit as before" do
      sign_in manager_of_both(:view_finance_dashboard, :view_expense_reports, :view_payroll,
                              scopes: { "view_payroll" => "business" })
      dashboard
      body_has_all_of(net_label, "15,666.66")
      dashboard_pdf
      body_has_all_of(net_label, "15,666.66")
    end
  end
end
