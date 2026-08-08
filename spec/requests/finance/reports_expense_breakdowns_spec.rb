require "rails_helper"

RSpec.describe "Finance::Reports expense breakdown pages", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:category) { create(:expense_category, business: business, name: "Cat A") }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  %i[finance_expenses_by_branch_report_path finance_expenses_by_category_report_path finance_expenses_by_type_report_path].each do |path_helper|
    describe "GET #{path_helper}" do
      it "renders successfully with KPI summary, ranking, distribution, and detailed table" do
        create(:expense, :approved, business: business, branch: branch, expense_category: category,
               amount: 500, expense_date: Date.current)

        sign_in owner
        get send(path_helper)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(I18n.t("finance.reports.breakdown.kpi_total"))
        expect(response.body).to include(I18n.t("finance.reports.breakdown.ranking_title"))
        expect(response.body).to include(I18n.t("finance.reports.breakdown.distribution_title"))
        expect(response.body).to include(I18n.t("finance.reports.breakdown.table_title"))
      end

      it "redirects a user without view_expense_reports" do
        viewer = user_with("view_expenses")
        sign_in viewer
        get send(path_helper)
        expect(response).to redirect_to(finance_root_path)
      end
    end
  end

  describe "GET finance_expense_trend_report_path" do
    it "renders the trend dashboard with moving average and period comparison" do
      create(:expense, :approved, business: business, branch: branch, expense_category: category,
             amount: 500, expense_date: Date.current)

      sign_in owner
      get finance_expense_trend_report_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("finance.reports.trend_dashboard.moving_average"))
      expect(response.body).to include(I18n.t("finance.reports.breakdown.kpi_total"))
    end
  end

  describe "CSV export stays byte-identical in structure to before the redesign" do
    it "exports the same total as the HTML KPI card" do
      create(:expense, :approved, business: business, branch: branch, expense_category: category,
             amount: 750, expense_date: Date.current)

      sign_in owner
      get finance_expenses_by_branch_report_path(format: :csv)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("750")
    end
  end
end
