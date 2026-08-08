require "rails_helper"

RSpec.describe "Finance::Dashboard", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:owner)    { create(:user, :owner, business: business) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  describe "GET /finance (executive dashboard)" do
    it "renders successfully for an owner with no data" do
      sign_in owner
      get finance_root_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("finance.dashboard.kpi.revenue"))
      expect(response.body).to include(I18n.t("finance.dashboard.kpi.net_profit"))
    end

    it "hides capability-gated widgets when the backing data model doesn't exist" do
      sign_in owner
      get finance_root_path
      expect(response.body).not_to include(I18n.t("finance.dashboard.kpi.supplier_payables"))
      expect(response.body).not_to include(I18n.t("finance.dashboard.kpi.cash_balance"))
      expect(response.body).not_to include(I18n.t("finance.dashboard.kpi.bank_balance"))
    end

    it "renders with expenses, custody, and a date filter applied" do
      category = create(:expense_category, business: business)
      create(:expense, business: business, branch: branch, expense_category: category,
             status: "approved", amount: 500, expense_date: Date.current)
      create(:custody_account, business: business, branch: branch, user: owner)

      sign_in owner
      get finance_root_path(from: Date.current.beginning_of_month, to: Date.current.end_of_month)
      expect(response).to have_http_status(:ok)
    end

    it "redirects a user without any finance permission" do
      outsider = create(:user, business: business)
      sign_in outsider
      get finance_root_path
      expect(response).to redirect_to(root_path)
    end

    it "hides revenue, net profit, margin, and branch profitability from a user without view_expense_reports" do
      viewer = user_with("view_expenses")
      sign_in viewer
      get finance_root_path
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(I18n.t("finance.dashboard.kpi.revenue"))
      expect(response.body).not_to include(I18n.t("finance.dashboard.kpi.net_profit"))
      expect(response.body).not_to include(I18n.t("finance.dashboard.kpi.profit_margin"))
      expect(response.body).not_to include(I18n.t("finance.dashboard.by_branch_revenue"))
      expect(response.body).not_to include(I18n.t("finance.dashboard.profitability"))
      # Expenses (not report-gated) should still be visible.
      expect(response.body).to include(I18n.t("finance.dashboard.kpi.expenses"))
    end

    it "shows revenue, net profit, and branch profitability to a user with view_expense_reports" do
      viewer = user_with("view_expenses", "view_expense_reports")
      sign_in viewer
      get finance_root_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("finance.dashboard.kpi.revenue"))
      expect(response.body).to include(I18n.t("finance.dashboard.kpi.net_profit"))
    end

    it "computes the Revenue KPI from a verified Daily Reconciliation's session amounts, not BranchRevenue" do
      cash_pm = PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true)
      dr = DailyReconciliation.create!(
        branch: branch, business: business, state: "verified",
        opened_at: Date.current.to_time, closed_at: Date.current.to_time, business_date: Date.current,
        verified_at: Date.current.to_time, verified_by_id: owner.id
      )
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                                 collected_amount: 4200, refund_amount: 200)
      # A manual BranchRevenue row must NOT be picked up (it's no longer a revenue source).
      create(:branch_revenue, business: business, branch: branch, period_month: Date.current.beginning_of_month, amount: 99_999)

      sign_in owner
      get finance_root_path(from: Date.current.beginning_of_month, to: Date.current.end_of_month)
      expect(response.body).to include("4,000.00")
      expect(response.body).not_to include("99,999.00")
    end

    it "shows zero revenue when there is no verified Daily Reconciliation for the period, not an error" do
      cash_pm = PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true)
      dr = DailyReconciliation.create!(
        branch: branch, business: business, state: "closed",
        opened_at: Date.current.to_time, closed_at: Date.current.to_time, business_date: Date.current
      )
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                                 collected_amount: 5000, refund_amount: 0)

      sign_in owner
      get finance_root_path(from: Date.current.beginning_of_month, to: Date.current.end_of_month)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("5,000.00")
    end

    it "includes the real revenue figure in the trend chart's monthly data, not a flat zero line" do
      # Regression test for a Time-vs-Date Hash#eql? bug that silently zeroed
      # out every point on the trend chart (see Finance::Reports::VerifiedRevenue#by_month).
      cash_pm = PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true)
      dr = DailyReconciliation.create!(
        branch: branch, business: business, state: "verified",
        opened_at: Date.current.to_time, closed_at: Date.current.to_time, business_date: Date.current,
        verified_at: Date.current.to_time, verified_by_id: owner.id
      )
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                                 collected_amount: 6000, refund_amount: 0)

      sign_in owner
      get finance_root_path(from: Date.current.beginning_of_month, to: Date.current.end_of_month)
      expect(response).to have_http_status(:ok)

      raw = response.body[/data-trend-chart-revenue-value="(.*?)"\s/, 1]
      revenue_series = JSON.parse(CGI.unescapeHTML(raw))
      expect(revenue_series.last.to_f).to eq(6000)
      expect(revenue_series.sum(&:to_f)).to eq(6000) # every other month genuinely has no data
    end
  end

  describe "revenue widget empty states" do
    it "shows the revenue-specific empty state (not a blank card, not the generic no-data message) for Revenue by Branch and Branch Profitability when no verified DR exists" do
      sign_in owner
      get finance_root_path(from: Date.current.beginning_of_month, to: Date.current.end_of_month)
      expect(response).to have_http_status(:ok)

      # Titles/full-report links stay — only the chart area is replaced.
      expect(response.body).to include(I18n.t("finance.dashboard.by_branch_revenue"))
      expect(response.body).to include(I18n.t("finance.dashboard.profitability"))
      expect(response.body.scan(I18n.t("finance.dashboard.no_revenue.title")).size).to eq(2)
      expect(response.body).to include(I18n.t("finance.dashboard.no_revenue.text"))
    end

    it "renders the actual charts once a verified DR exists for the period, not the empty state" do
      cash_pm = PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true)
      dr = DailyReconciliation.create!(
        branch: branch, business: business, state: "verified",
        opened_at: Date.current.to_time, closed_at: Date.current.to_time, business_date: Date.current,
        verified_at: Date.current.to_time, verified_by_id: owner.id
      )
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                                 collected_amount: 3000, refund_amount: 0)

      sign_in owner
      get finance_root_path(from: Date.current.beginning_of_month, to: Date.current.end_of_month)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(I18n.t("finance.dashboard.no_revenue.title"))
      expect(response.body).to include('data-chart-type-value="doughnut"')
      expect(response.body).to include("data-sortable-bars-target=\"canvas\"")
    end

    it "does not show the revenue empty state to a user without view_expense_reports (the whole card is hidden instead)" do
      viewer = user_with("view_expenses")
      sign_in viewer
      get finance_root_path
      expect(response.body).not_to include(I18n.t("finance.dashboard.no_revenue.title"))
    end
  end

  describe "GET /finance/dashboard/export_pdf" do
    it "streams a PDF for an owner" do
      allow(Finance::Dashboard::PdfRenderer).to receive(:render).and_return("%PDF-1.4 stub")

      sign_in owner
      get finance_dashboard_export_pdf_path
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/pdf")
    end
  end
end
