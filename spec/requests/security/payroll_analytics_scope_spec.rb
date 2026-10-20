require "rails_helper"

# Payroll analytics follow the view_payroll scope (decision of 2026-10-19,
# option A — as the Finance reports and the API payroll report): the payroll
# dashboard (recent totals, trend, branch breakdown, top earners,
# recommendations), the payroll-period list totals and the operations
# dashboard's payroll-derived recommendations are computed only from the
# entries the viewer may see (PayrollEntryPolicy::Scope), and the branch
# breakdown lists only branches of that scope. Without view_payroll: nothing.
# No request parameter widens it.
RSpec.describe "Payroll analytics scope", type: :request do
  let(:business) { create(:business) }
  let(:alpha)    { create(:branch, business: business, name: "Alpha Branch") }
  let(:bravo)    { create(:branch, business: business, name: "Bravo Branch") }
  let(:charlie)  { create(:branch, business: business, name: "Charlie Branch") }
  let(:month)    { Date.current.prev_month.beginning_of_month }

  # Net pay: Alpha 1,111.11 · Bravo 2,222.22 · Charlie 4,444.44 (with 2,000
  # overtime — a "high branch overtime" recommendation). Totals:
  # Bravo + Charlie 6,666.66 · all 7,777.77.
  let!(:period) do
    create(:payroll_period, :finalized, business: business, period_year: month.year, period_month: month.month).tap do |p|
      create(:payroll_entry, payroll_period: p, user: employee_at(alpha, "Ann"), net_salary: 1_111.11)
      create(:payroll_entry, payroll_period: p, user: employee_at(bravo, "Ben"), net_salary: 2_222.22)
      create(:payroll_entry, payroll_period: p, user: employee_at(charlie, "Cid"), net_salary: 4_444.44, total_overtime: 2_000)
    end
  end

  ALPHA   = %w[1,111].freeze
  BRAVO   = %w[2,222].freeze
  CHARLIE = %w[4,444].freeze
  SUMS    = %w[6,667 7,778 3,333 5,556].freeze # every multi-branch total

  def employee_at(branch, first_name)
    create(:user, business: business, first_name: first_name, last_name: "Staff").tap do |u|
      create(:shift_assignment, business: business, user: u, branch: branch,
                                effective_from: month - 1.month, effective_to: nil)
    end
  end

  def analyst(scope: nil, extra: [])
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}", permissions: %w[view_payroll view_payroll_analytics] + extra,
      permission_scopes: scope ? { "view_payroll" => scope } : {}
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  # Manages Alpha, area-manages Bravo and Charlie.
  def manager(scope:, extra: [])
    analyst(scope: scope, extra: extra).tap do |u|
      alpha.update_column(:branch_manager_id, u.id)
      bravo.update_column(:area_manager_id, u.id)
      charlie.update_column(:area_manager_id, u.id)
    end
  end

  def overtime_alert(branch) = I18n.t("recommendations.high_branch_overtime.title", branch: branch.name)
  def scope_note = I18n.t("payroll_dashboard.scope_note")

  def body_has(*values)  = values.flatten.each { |v| expect(response.body).to include(v) }
  def body_lacks(*values) = values.flatten.each { |v| expect(response.body).not_to include(v) }

  describe "payroll dashboard" do
    def dashboard(**params)
      get payroll_dashboard_path(params)
      expect(response).to have_http_status(:ok)
    end

    it "branch scope: Alpha only — totals, trend, branch breakdown, top earners, recommendations" do
      sign_in manager(scope: "branch")
      dashboard

      body_has(ALPHA, alpha.name, scope_note)
      body_lacks(BRAVO, CHARLIE, SUMS, bravo.name, charlie.name, overtime_alert(charlie))
    end

    it "area scope: Bravo and Charlie, not the managed Alpha" do
      sign_in manager(scope: "area")
      dashboard

      body_has("6,667", BRAVO, CHARLIE, bravo.name, charlie.name, overtime_alert(charlie), scope_note)
      body_lacks(ALPHA, "7,778", alpha.name)
    end

    it "default scope (none configured): managed + area-managed branches" do
      sign_in manager(scope: nil)
      dashboard
      body_has("7,778", alpha.name, bravo.name, charlie.name)
    end

    it "explicit business scope: everything, no scope note" do
      sign_in analyst(scope: "business")
      dashboard

      body_has("7,778", ALPHA, BRAVO, CHARLIE, alpha.name, bravo.name, charlie.name, overtime_alert(charlie))
      body_lacks(scope_note)
    end

    # :super_admin is the owner (an alias trait); one per business — a second
    # owner-making trait would silently replace the first.
    it "the owner (super admin) sees everything" do
      sign_in create(:user, :super_admin, business: business)
      dashboard
      body_has("7,778", alpha.name, bravo.name, charlie.name)
      body_lacks(scope_note)
    end

    it "a branch_id parameter does not widen it" do
      sign_in manager(scope: "branch")
      dashboard(branch_id: charlie.id, business_id: business.id)
      body_lacks(CHARLIE, SUMS, charlie.name)
    end

    it "no view_payroll: refused — even with view_payroll_analytics stored without its dependency" do
      sign_in create(:user, business: business)
      get payroll_dashboard_path
      expect(response).to redirect_to(root_path)

      broken = analyst(scope: "business")
      broken.permission_role.update_column(:permissions, %w[view_payroll_analytics])
      sign_in broken
      get payroll_dashboard_path
      expect(response).to redirect_to(root_path)
      body_lacks(ALPHA, BRAVO, CHARLIE, SUMS)
    end

    it "a view_payroll scope that covers nobody shows no payroll at all" do
      sign_in analyst(scope: "self")
      dashboard
      body_lacks(ALPHA, BRAVO, CHARLIE, SUMS, alpha.name, bravo.name, charlie.name)
    end
  end

  describe "payroll period list totals" do
    def period_list
      get payroll_periods_path
      expect(response).to have_http_status(:ok)
    end

    it "branch scope: the period's totals cover Alpha only" do
      sign_in manager(scope: "branch")
      period_list
      body_has(ALPHA, scope_note)
      body_lacks(BRAVO, CHARLIE, SUMS)
    end

    it "area scope: Bravo + Charlie" do
      sign_in manager(scope: "area")
      period_list
      body_has("6,667")
      body_lacks(ALPHA, "7,778")
    end

    it "business scope and the owner: the whole period" do
      sign_in analyst(scope: "business")
      period_list
      body_has("7,778")
      body_lacks(scope_note)

      sign_in create(:user, :owner, business: business)
      period_list
      body_has("7,778")
    end
  end

  describe "operations dashboard recommendations" do
    def operations
      get operations_dashboard_path
      expect(response).to have_http_status(:ok)
    end

    it "without view_payroll: no payroll-derived recommendation" do
      role = business.permission_roles.create!(name: "Reports", permissions: %w[view_reports])
      sign_in create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
      operations
      body_lacks(overtime_alert(charlie))
    end

    it "with view_payroll outside Charlie: no Charlie overtime alert" do
      sign_in manager(scope: "branch", extra: %w[view_reports])
      operations
      body_lacks(overtime_alert(charlie))
    end

    it "with view_payroll covering Charlie: the alert as before" do
      sign_in analyst(scope: "business", extra: %w[view_reports])
      operations
      body_has(overtime_alert(charlie))
    end
  end
end
