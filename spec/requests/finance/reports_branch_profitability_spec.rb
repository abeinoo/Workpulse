require "rails_helper"

RSpec.describe "Finance::Reports branch profitability dashboard", type: :request do
  let(:business) { create(:business) }
  let(:branch_a) { create(:branch, business: business, name: "Branch A") }
  let(:branch_b) { create(:branch, business: business, name: "Branch B") }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:category) { create(:expense_category, business: business, name: "Ops") }
  let(:month)    { Date.current.beginning_of_month }

  def verified_dr(branch:, business_date:, amount:)
    dr = DailyReconciliation.create!(
      branch: branch, business: business, state: "verified",
      opened_at: business_date.to_time, closed_at: business_date.to_time,
      business_date: business_date,
      verified_at: business_date.to_time, verified_by_id: owner.id
    )
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: cash_pm.name,
                               collected_amount: amount, refund_amount: 0)
    dr
  end

  before do
    verified_dr(branch: branch_a, business_date: month + 5.days, amount: 1000)
    verified_dr(branch: branch_b, business_date: month + 5.days, amount: 400)
    create(:expense, :approved, business: business, branch: branch_a, expense_category: category,
           amount: 200, expense_date: month + 5.days)

    sign_in owner
  end

  it "renders the flagship dashboard with KPI, chart, ranking, and branch cards for every branch" do
    get finance_branch_profitability_report_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(I18n.t("finance.reports.profitability_dashboard.chart_title"))
    expect(response.body).to include(I18n.t("finance.reports.profitability_dashboard.ranking_title"))
    expect(response.body).to include("Branch A")
    expect(response.body).to include("Branch B")
  end

  it "filters every widget to the selected branch via branch_id, preserving month and year" do
    get finance_branch_profitability_report_path(branch_id: branch_a.id)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Branch A")
    expect(response.body).to include("branch_id=#{branch_a.id}")

    branch_names = Nokogiri::HTML(response.body).css(".branch-card__name").map(&:text)
    expect(branch_names).to eq([ "Branch A" ])
  end

  it "keeps the CSV export unfiltered by branch_id and matching the on-screen total" do
    get finance_branch_profitability_report_path(branch_id: branch_a.id, format: :csv)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Branch A")
    expect(response.body).to include("Branch B")
  end

  it "redirects a user without view_expense_reports" do
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: [ "view_expenses" ])
    viewer = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
    sign_in viewer

    get finance_branch_profitability_report_path
    expect(response).to redirect_to(finance_root_path)
  end

  describe "sales-branch scoping" do
    let!(:laundry) { create(:branch, business: business, name: "Laundry Branch", branch_type: "laundry") }

    it "only lists sales branches in the branch selector" do
      get finance_branch_profitability_report_path

      options = Nokogiri::HTML(response.body).css("select[name='branch_id'] option").map(&:text)
      expect(options).to include("Branch A", "Branch B")
      expect(options).not_to include("Laundry Branch")
    end

    it "never renders a non-sales branch in the ranking/cards/table even when it has real data" do
      verified_dr(branch: laundry, business_date: month + 5.days, amount: 4000)
      create(:expense, :approved, business: business, branch: laundry, expense_category: category,
             amount: 500, expense_date: month + 5.days)

      get finance_branch_profitability_report_path

      expect(response.body).not_to include("Laundry Branch")
    end

    it "handles a manually-submitted non-sales branch_id safely (no crash, branch not selectable)" do
      get finance_branch_profitability_report_path(branch_id: laundry.id)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Laundry Branch")
      branch_names = Nokogiri::HTML(response.body).css(".branch-card__name").map(&:text)
      expect(branch_names).to be_empty
    end
  end
end
