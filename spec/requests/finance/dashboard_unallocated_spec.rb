require "rails_helper"

# The finance dashboard and unallocated costs (floating employees): counted
# once in the business-wide view — expenses and net profit alike — and left
# out of every expense figure and the net profit of a branch view (a branch
# filter, or a viewer whose branch scope is narrower than the business).
RSpec.describe "Finance::Dashboard — unallocated costs", type: :request do
  let(:business) { create(:business) }
  let!(:branch)  { create(:branch, business: business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:period)   { create(:payroll_period, business: business, period_year: Date.current.year, period_month: Date.current.month) }
  let(:category) { create(:expense_category, business: business) }

  before do
    create(:expense, :approved, business: business, branch: branch, amount: 1_000, expense_category: category)
    create(:expense, :approved, business: business, branch: nil, amount: 500, expense_category: category,
                                source_payroll_period: period, unallocated: true)
    floating = create(:user, business: business)
    create(:shift_assignment, :floating, user: floating, shift: create(:shift, :hour_based, business: business),
                                         effective_from: Date.current.beginning_of_month - 1.month)
    create(:payroll_entry, payroll_period: period, user: floating, base_salary: 300, total_overtime: 0, total_bonuses: 0, net_salary: 300)
  end

  def values = response.body.scan(/data-count-up-target-value="(-?[\d.]+)"/).flatten

  describe "an owner" do
    before { sign_in owner }

    it "counts the unallocated costs once in the business-wide expenses and net profit, which reconcile" do
      get finance_root_path

      expect(response).to have_http_status(:ok)
      expect(values).to include("1500.0", "-1800.0") # expenses 1,000 + 500; net −(1,500 + 300 floating salary)
    end

    it "leaves them out of every expense figure and the net profit of a single-branch view" do
      get finance_root_path, params: { branch_id: branch.id }

      expect(response).to have_http_status(:ok)
      expect(values).to include("1000.0", "-1000.0") # expenses and net reconcile: no revenue, no branch payroll
      expect(response.body).not_to include("1500.0") # nor in the category chart or the trend
      expect(response.body).not_to include(I18n.t("finance.reports.unallocated"))
    end
  end

  describe "a viewer limited to some branches" do
    let!(:branch_b) { create(:branch, business: business) }
    let!(:branch_c) { create(:branch, business: business) }

    def viewer(*permissions)
      role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: [ "view_finance_dashboard", *permissions ])
      create(:user, business: business).tap do |u|
        u.update_column(:permission_role_id, role.id)
        [ branch, branch_b ].each { |b| b.update!(branch_manager: u) }
      end
    end

    before do
      create(:expense, :approved, business: business, branch: branch_b, amount: 2_000, expense_category: category)
      create(:expense, :approved, business: business, branch: branch_c, amount: 4_000, expense_category: category)
    end

    it "sees only their branches' expenses, never the unallocated ones (multi-branch scope)" do
      sign_in viewer("view_expenses")

      get finance_root_path

      expect(response).to have_http_status(:ok)
      expect(values).to include("3000.0")
      expect(values).not_to include("3500.0", "7500.0", "500.0")
    end

    it "gains nothing without expense access" do
      sign_in viewer

      get finance_root_path

      expect(response).to have_http_status(:ok)
      expect(values).not_to include("500.0", "1500.0", "3000.0", "3500.0", "7500.0")
    end
  end
end
