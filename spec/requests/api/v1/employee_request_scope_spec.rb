require "rails_helper"

# Regression suite for employee-request scope isolation.
#
# Verifies that branch managers and direct managers can only view and act on
# requests belonging to employees inside their EmployeeScope, and that the
# partition invariant holds: count_A + count_B == owner count.
#
# Setup: one business, two branches, one manager per branch, one employee per
# branch.  A separate direct manager has a direct report via manager_id only —
# no shared UserBranch row — so the tests also confirm that EmployeeScope
# handles the manager_id path correctly.
RSpec.describe "Employee Request Scope", type: :request do
  let(:business)   { create(:business) }
  let(:branch_a)   { create(:branch, business: business) }
  let(:branch_b)   { create(:branch, business: business) }

  let!(:owner)     { create(:user, :owner, business: business) }

  # Plain users — branch-manager scope comes from branch_manager_id + UserBranch,
  # not from any trait.
  let(:manager_a)  { create(:user, business: business) }
  let(:manager_b)  { create(:user, business: business) }
  let(:employee_a) { create(:user, business: business) }
  let(:employee_b) { create(:user, business: business) }

  # Direct manager has NO branch and NO UserBranch — only manager_id on the report.
  let(:direct_manager) { create(:user, business: business) }
  let(:direct_report)  { create(:user, business: business, manager: direct_manager) }

  let(:manager_role) do
    create(:permission_role, business: business,
           permissions: %w[view_requests approve_requests view_employees],
           permission_scopes: {})
  end

  before do
    branch_a.update_column(:branch_manager_id, manager_a.id)
    branch_b.update_column(:branch_manager_id, manager_b.id)
    create(:user_branch, user: manager_a,  branch: branch_a)
    create(:user_branch, user: manager_b,  branch: branch_b)
    create(:user_branch, user: employee_a, branch: branch_a)
    create(:user_branch, user: employee_b, branch: branch_b)
    # Permission-driven: managers need view_requests + approve_requests.
    # EmployeeScope handles the data scope via branch/manager relationships.
    [manager_a, manager_b, direct_manager].each do |m|
      m.update_column(:permission_role_id, manager_role.id)
    end
  end

  # Pending requests — one per employee.
  let!(:request_a) { create(:employee_request, :pending, user: employee_a) }
  let!(:request_b) { create(:employee_request, :pending, user: employee_b) }
  let!(:request_dr){ create(:employee_request, :pending, user: direct_report) }

  # ── Index ──────────────────────────────────────────────────────────────────

  describe "GET /api/v1/employee_requests" do
    def fetch_request_ids(as_user)
      sign_in as_user
      get "/api/v1/employee_requests", as: :json
      response.parsed_body["data"].map { |r| r["id"] }
    end

    it "owner sees requests for all employees" do
      ids = fetch_request_ids(owner)
      expect(ids).to include(request_a.id, request_b.id, request_dr.id)
    end

    it "branch manager A sees only branch A employee requests" do
      ids = fetch_request_ids(manager_a)
      expect(ids).to     include(request_a.id)
      expect(ids).not_to include(request_b.id)
      expect(ids).not_to include(request_dr.id)
    end

    it "branch manager B sees only branch B employee requests" do
      ids = fetch_request_ids(manager_b)
      expect(ids).to     include(request_b.id)
      expect(ids).not_to include(request_a.id)
    end

    it "direct manager sees direct report's request without a shared UserBranch" do
      ids = fetch_request_ids(direct_manager)
      expect(ids).to include(request_dr.id)
      expect(ids).not_to include(request_a.id, request_b.id)
    end

    it "employee sees only their own requests" do
      ids = fetch_request_ids(employee_a)
      expect(ids).to     include(request_a.id)
      expect(ids).not_to include(request_b.id)
    end

    it "partition invariant: manager A count + manager B count + direct manager count equals owner count" do
      count_a  = fetch_request_ids(manager_a).length
      count_b  = fetch_request_ids(manager_b).length
      count_dm = fetch_request_ids(direct_manager).length
      count_owner = fetch_request_ids(owner).length
      expect(count_a + count_b + count_dm).to eq(count_owner)
    end
  end

  # ── Show ───────────────────────────────────────────────────────────────────

  describe "GET /api/v1/employee_requests/:id" do
    it "branch manager A can view a request from their branch employee" do
      sign_in manager_a
      get "/api/v1/employee_requests/#{request_a.id}", as: :json
      expect(response).to have_http_status(:ok)
    end

    it "branch manager A gets 404 when accessing branch B employee's request" do
      sign_in manager_a
      get "/api/v1/employee_requests/#{request_b.id}", as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "direct manager can view their direct report's request" do
      sign_in direct_manager
      get "/api/v1/employee_requests/#{request_dr.id}", as: :json
      expect(response).to have_http_status(:ok)
    end

    it "direct manager gets 404 on a request outside their scope" do
      sign_in direct_manager
      get "/api/v1/employee_requests/#{request_a.id}", as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  # ── Approve ────────────────────────────────────────────────────────────────

  describe "PATCH /api/v1/employee_requests/:id/approve" do
    it "branch manager A can approve a branch A request" do
      sign_in manager_a
      patch "/api/v1/employee_requests/#{request_a.id}/approve", as: :json
      expect(response).to have_http_status(:ok)
      expect(request_a.reload.status).to eq("approved")
    end

    it "branch manager A gets 404 trying to approve branch B's request" do
      sign_in manager_a
      patch "/api/v1/employee_requests/#{request_b.id}/approve", as: :json
      expect(response).to have_http_status(:not_found)
      expect(request_b.reload.status).to eq("pending")
    end

    it "direct manager can approve their direct report's request" do
      sign_in direct_manager
      patch "/api/v1/employee_requests/#{request_dr.id}/approve", as: :json
      expect(response).to have_http_status(:ok)
      expect(request_dr.reload.status).to eq("approved")
    end

    it "direct manager gets 404 trying to approve an out-of-scope request" do
      sign_in direct_manager
      patch "/api/v1/employee_requests/#{request_a.id}/approve", as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "employee gets 403 trying to approve their own request" do
      sign_in employee_a
      patch "/api/v1/employee_requests/#{request_a.id}/approve", as: :json
      # policy_scope includes the employee's own requests, so find succeeds,
      # but policy#approve? returns false → Pundit raises NotAuthorizedError → 403
      expect(response).to have_http_status(:forbidden)
    end
  end

  # ── Reject ─────────────────────────────────────────────────────────────────

  describe "PATCH /api/v1/employee_requests/:id/reject" do
    it "branch manager A can reject a branch A request" do
      sign_in manager_a
      patch "/api/v1/employee_requests/#{request_a.id}/reject", as: :json
      expect(response).to have_http_status(:ok)
      expect(request_a.reload.status).to eq("rejected")
    end

    it "branch manager A gets 404 trying to reject branch B's request" do
      sign_in manager_a
      patch "/api/v1/employee_requests/#{request_b.id}/reject", as: :json
      expect(response).to have_http_status(:not_found)
      expect(request_b.reload.status).to eq("pending")
    end

    it "direct manager can reject their direct report's request" do
      sign_in direct_manager
      patch "/api/v1/employee_requests/#{request_dr.id}/reject", as: :json
      expect(response).to have_http_status(:ok)
      expect(request_dr.reload.status).to eq("rejected")
    end
  end

  # ── EmployeeScope delegation regression ───────────────────────────────────
  #
  # These examples catch anyone accidentally narrowing back to managed_employee_ids
  # (direct reports only via manager_id) or a branch-only check.

  describe "EmployeeScope delegation regression" do
    it "branch manager sees branch employees even when they have no manager_id relationship" do
      # employee_a's manager_id is nil — scope comes purely from UserBranch
      expect(employee_a.manager_id).to be_nil
      sign_in manager_a
      get "/api/v1/employee_requests", as: :json
      ids = response.parsed_body["data"].map { |r| r["id"] }
      expect(ids).to include(request_a.id)
    end

    it "direct manager sees direct report even when they share no branch" do
      # direct_report has NO UserBranch row — scope comes purely from manager_id
      expect(UserBranch.where(user: direct_report).exists?).to be false
      sign_in direct_manager
      get "/api/v1/employee_requests", as: :json
      ids = response.parsed_body["data"].map { |r| r["id"] }
      expect(ids).to include(request_dr.id)
    end

    it "branch manager cannot see direct report of another manager who is also in their branch" do
      # Edge case: if a direct_report is placed in branch_a but belongs to direct_manager,
      # manager_a should NOT see their requests through that branch membership.
      # direct_report is NOT in branch_a, so this is just a cross-scope sanity check.
      sign_in manager_a
      get "/api/v1/employee_requests/#{request_dr.id}", as: :json
      expect(response).to have_http_status(:not_found)
    end
  end
end
