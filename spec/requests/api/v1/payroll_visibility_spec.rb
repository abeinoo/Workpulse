require "rails_helper"
require "csv"

# Regression suite for payroll scope-awareness across all output surfaces.
#
# Verifies that the same period returns different data depending on who asks,
# and that no surface (entries list, summary totals, CSV export) leaks rows
# across branch or business boundaries.
#
# Setup: one business, two branches, one manager per branch, one employee per branch.
# Owner and accountant cover the "see everything" cases.
RSpec.describe "Payroll Scope Visibility", type: :request do
  let(:business)   { create(:business) }
  let(:branch_a)   { create(:branch, business: business) }
  let(:branch_b)   { create(:branch, business: business) }

  # Owners see the full business picture.
  let!(:owner)     { create(:user, :owner,     business: business) }
  # Accountants have view_payroll with business_wide scope (see :accountant factory trait).
  let(:accountant) { create(:user, :accountant, business: business) }

  # Managers are plain users — scope comes from the branch_manager_id column, not a trait,
  # so each manager is explicitly associated with exactly one branch below.
  let(:manager_a)  { create(:user, business: business) }
  let(:manager_b)  { create(:user, business: business) }
  let(:employee_a) { create(:user, business: business) }
  let(:employee_b) { create(:user, business: business) }

  let(:period)    { create(:payroll_period, business: business) }
  let!(:entry_a)  { create(:payroll_entry, payroll_period: period, user: employee_a, base_salary: 5_000.0, net_salary: 4_800.0) }
  let!(:entry_b)  { create(:payroll_entry, payroll_period: period, user: employee_b, base_salary: 3_000.0, net_salary: 2_900.0) }

  let(:manager_role) do
    create(:permission_role, business: business,
           permissions: %w[view_payroll view_employees],
           permission_scopes: {})
  end

  before do
    branch_a.update_column(:branch_manager_id, manager_a.id)
    branch_b.update_column(:branch_manager_id, manager_b.id)
    create(:user_branch, user: manager_a,  branch: branch_a)
    create(:user_branch, user: manager_b,  branch: branch_b)
    create(:user_branch, user: employee_a, branch: branch_a)
    create(:user_branch, user: employee_b, branch: branch_b)
    # Permission-driven: branch managers need view_payroll permission.
    # Scope is resolved by EmployeeScope via the branch_manager_id relationship.
    manager_a.update_column(:permission_role_id, manager_role.id)
    manager_b.update_column(:permission_role_id, manager_role.id)
  end

  # ── Entries index ──────────────────────────────────────────────────────────

  describe "GET /api/v1/payroll_periods/:id/payroll_entries" do
    def fetch_entries(as_user)
      sign_in as_user
      get "/api/v1/payroll_periods/#{period.id}/payroll_entries", as: :json
      response.parsed_body["data"]
    end

    it "owner sees entries for both employees" do
      ids = fetch_entries(owner).map { |e| e["user_id"] }
      expect(ids).to include(employee_a.id, employee_b.id)
    end

    it "accountant sees entries for both employees" do
      ids = fetch_entries(accountant).map { |e| e["user_id"] }
      expect(ids).to include(employee_a.id, employee_b.id)
    end

    it "branch manager A sees only their branch employee" do
      ids = fetch_entries(manager_a).map { |e| e["user_id"] }
      expect(ids).to     include(employee_a.id)
      expect(ids).not_to include(employee_b.id)
    end

    it "branch manager B sees only their branch employee" do
      ids = fetch_entries(manager_b).map { |e| e["user_id"] }
      expect(ids).to     include(employee_b.id)
      expect(ids).not_to include(employee_a.id)
    end

    it "employee sees nothing while the period is still draft" do
      expect(fetch_entries(employee_a)).to be_empty
    end
  end

  # ── Summary endpoint ───────────────────────────────────────────────────────

  describe "GET /api/v1/reports/payroll/summary" do
    def fetch_summary(as_user)
      sign_in as_user
      get "/api/v1/reports/payroll/summary",
          params: { payroll_period_id: period.id }, as: :json
      response.parsed_body["data"]
    end

    it "owner summary includes both employees and full totals" do
      data = fetch_summary(owner)
      expect(data["totals"]["employees"]).to eq(2)
      expect(data["totals"]["base_salary"]).to eq(8_000.0)
    end

    it "accountant summary includes the full business totals" do
      data = fetch_summary(accountant)
      expect(data["totals"]["employees"]).to eq(2)
      expect(data["totals"]["base_salary"]).to eq(8_000.0)
    end

    it "branch manager A summary reflects only branch A" do
      data    = fetch_summary(manager_a)
      user_ids = data["entries"].map { |e| e["user_id"] }
      expect(user_ids).to contain_exactly(employee_a.id)
      expect(data["totals"]["employees"]).to eq(1)
      expect(data["totals"]["base_salary"]).to eq(5_000.0)
    end

    it "branch manager B summary reflects only branch B" do
      data    = fetch_summary(manager_b)
      user_ids = data["entries"].map { |e| e["user_id"] }
      expect(user_ids).to contain_exactly(employee_b.id)
      expect(data["totals"]["base_salary"]).to eq(3_000.0)
    end

    it "branch manager A does not see branch B's employee in their summary" do
      entries = fetch_summary(manager_a)["entries"]
      ids     = entries.map { |e| e["user_id"] }
      expect(ids).not_to include(employee_b.id)
    end

    it "manager totals partition cleanly — A + B equals the owner total" do
      total_owner = fetch_summary(owner)["totals"]["base_salary"]
      total_a     = fetch_summary(manager_a)["totals"]["base_salary"]
      total_b     = fetch_summary(manager_b)["totals"]["base_salary"]
      expect(total_a + total_b).to eq(total_owner)
    end
  end

  # ── CSV export endpoint ────────────────────────────────────────────────────

  describe "GET /api/v1/reports/payroll/export" do
    def fetch_csv(as_user)
      sign_in as_user
      get "/api/v1/reports/payroll/export",
          params: { payroll_period_id: period.id }
      CSV.parse(response.body)
    end

    # user_id (column 0) is a positive integer string in data rows.
    def data_rows(rows)  = rows.select { |r| r[0].to_i > 0 }
    def totals_row(rows) = rows.find   { |r| r[1] == "TOTALS" }
    def employee_names(rows) = data_rows(rows).map { |r| r[1] }

    it "owner export contains both employees" do
      rows = fetch_csv(owner)
      expect(employee_names(rows)).to include(employee_a.full_name, employee_b.full_name)
    end

    it "owner export TOTALS reflects the full payroll" do
      rows = fetch_csv(owner)
      expect(totals_row(rows)[3].to_f).to eq(8_000.0)
    end

    it "branch manager A export contains only their employee" do
      rows = fetch_csv(manager_a)
      expect(employee_names(rows)).to     include(employee_a.full_name)
      expect(employee_names(rows)).not_to include(employee_b.full_name)
    end

    it "branch manager A export TOTALS reflects only their payroll" do
      rows = fetch_csv(manager_a)
      expect(totals_row(rows)[3].to_f).to eq(5_000.0)
    end

    it "branch manager B export contains only their employee" do
      rows = fetch_csv(manager_b)
      expect(employee_names(rows)).to     include(employee_b.full_name)
      expect(employee_names(rows)).not_to include(employee_a.full_name)
    end

    it "branch manager B export TOTALS reflects only their payroll" do
      rows = fetch_csv(manager_b)
      expect(totals_row(rows)[3].to_f).to eq(3_000.0)
    end

    it "CSV partition invariant: A totals + B totals equal owner totals" do
      full  = totals_row(fetch_csv(owner))[3].to_f
      part_a = totals_row(fetch_csv(manager_a))[3].to_f
      part_b = totals_row(fetch_csv(manager_b))[3].to_f
      expect(part_a + part_b).to eq(full)
    end
  end

  # ── Cross-business leakage prevention ─────────────────────────────────────

  describe "cross-business access prevention" do
    let(:other_user) { create(:user) } # belongs to a different business entirely

    it "cannot access summary for another business's period" do
      sign_in other_user
      get "/api/v1/reports/payroll/summary",
          params: { payroll_period_id: period.id }, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "cannot access export for another business's period" do
      sign_in other_user
      get "/api/v1/reports/payroll/export",
          params: { payroll_period_id: period.id }
      expect(response).to have_http_status(:not_found)
    end

    it "receives empty entries when querying another business's payroll period" do
      sign_in other_user
      get "/api/v1/payroll_periods/#{period.id}/payroll_entries", as: :json
      # policy_scope filters to own business — no entries found, not a 404
      expect(response.parsed_body["data"]).to be_empty
    end
  end

  # ── Finalized period: scope persists ──────────────────────────────────────

  describe "scope-awareness survives state transitions" do
    # Use :last_month so the period_year/month uniqueness constraint doesn't conflict with `period`.
    let(:finalized_period) { create(:payroll_period, :finalized, :last_month, business: business) }
    let!(:fin_entry_a) { create(:payroll_entry, payroll_period: finalized_period, user: employee_a, base_salary: 5_000.0) }
    let!(:fin_entry_b) { create(:payroll_entry, payroll_period: finalized_period, user: employee_b, base_salary: 3_000.0) }

    it "branch manager A still sees only their employee after finalization" do
      sign_in manager_a
      get "/api/v1/reports/payroll/summary",
          params: { payroll_period_id: finalized_period.id }, as: :json
      data     = response.parsed_body["data"]
      user_ids = data["entries"].map { |e| e["user_id"] }
      expect(user_ids).to contain_exactly(employee_a.id)
    end

    it "employees can see their own entry once the period is finalized" do
      sign_in employee_a
      get "/api/v1/payroll_periods/#{finalized_period.id}/payroll_entries", as: :json
      ids = response.parsed_body["data"].map { |e| e["user_id"] }
      expect(ids).to include(employee_a.id)
      expect(ids).not_to include(employee_b.id)
    end
  end
end
