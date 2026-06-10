require "rails_helper"

# Regression suite for employee-request scope isolation.
#
# Verifies that branch managers can only view and act on requests belonging to
# employees inside their EmployeeScope, and that the partition invariant holds:
# count_A + count_B + count_C == owner count.
#
# Setup: one business, three branches, one manager per branch, one employee per
# branch. Branch membership is shift-driven — an employee belongs to a branch
# while they hold an active ShiftAssignment to it. There is no UserBranch and no
# manager_id ownership.
RSpec.describe "Employee Request Scope", type: :request do
  let(:business)   { create(:business) }
  let(:branch_a)   { create(:branch, business: business) }
  let(:branch_b)   { create(:branch, business: business) }
  let(:branch_c)   { create(:branch, business: business) }

  let!(:owner)     { create(:user, :owner, business: business) }

  let(:shift)      { create(:shift, :fixed_time, business: business) }

  # Plain users — branch-manager scope comes from branch_manager_id; membership
  # comes from active ShiftAssignments.
  let(:manager_a)  { create(:user, business: business) }
  let(:manager_b)  { create(:user, business: business) }
  let(:manager_c)  { create(:user, business: business) }
  let(:employee_a) { create(:user, business: business) }
  let(:employee_b) { create(:user, business: business) }
  let(:employee_c) { create(:user, business: business) }

  let(:manager_role) do
    create(:permission_role, business: business,
           permissions: %w[view_requests approve_requests view_employees],
           permission_scopes: {})
  end

  before do
    branch_a.update_column(:branch_manager_id, manager_a.id)
    branch_b.update_column(:branch_manager_id, manager_b.id)
    branch_c.update_column(:branch_manager_id, manager_c.id)
    create(:shift_assignment, user: employee_a, branch: branch_a, shift: shift)
    create(:shift_assignment, user: employee_b, branch: branch_b, shift: shift)
    create(:shift_assignment, user: employee_c, branch: branch_c, shift: shift)
    # Permission-driven: managers need view_requests + approve_requests.
    # EmployeeScope handles the data scope via branch relationships.
    [ manager_a, manager_b, manager_c ].each do |m|
      m.update_column(:permission_role_id, manager_role.id)
    end
  end

  # Pending requests — one per employee.
  let!(:request_a) { create(:employee_request, :pending, user: employee_a) }
  let!(:request_b) { create(:employee_request, :pending, user: employee_b) }
  let!(:request_c) { create(:employee_request, :pending, user: employee_c) }

  # ── Index ──────────────────────────────────────────────────────────────────

  describe "GET /api/v1/employee_requests" do
    def fetch_request_ids(as_user)
      sign_in as_user
      get "/api/v1/employee_requests", as: :json
      response.parsed_body["data"].map { |r| r["id"] }
    end

    it "owner sees requests for all employees" do
      ids = fetch_request_ids(owner)
      expect(ids).to include(request_a.id, request_b.id, request_c.id)
    end

    it "branch manager A sees only branch A employee requests" do
      ids = fetch_request_ids(manager_a)
      expect(ids).to     include(request_a.id)
      expect(ids).not_to include(request_b.id)
      expect(ids).not_to include(request_c.id)
    end

    it "branch manager B sees only branch B employee requests" do
      ids = fetch_request_ids(manager_b)
      expect(ids).to     include(request_b.id)
      expect(ids).not_to include(request_a.id)
    end

    it "branch manager C sees their branch employee's request" do
      ids = fetch_request_ids(manager_c)
      expect(ids).to include(request_c.id)
      expect(ids).not_to include(request_a.id, request_b.id)
    end

    it "employee sees only their own requests" do
      ids = fetch_request_ids(employee_a)
      expect(ids).to     include(request_a.id)
      expect(ids).not_to include(request_b.id)
    end

    it "partition invariant: manager A + B + C count equals owner count" do
      count_a  = fetch_request_ids(manager_a).length
      count_b  = fetch_request_ids(manager_b).length
      count_c  = fetch_request_ids(manager_c).length
      count_owner = fetch_request_ids(owner).length
      expect(count_a + count_b + count_c).to eq(count_owner)
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

    it "branch manager C can view their branch employee's request" do
      sign_in manager_c
      get "/api/v1/employee_requests/#{request_c.id}", as: :json
      expect(response).to have_http_status(:ok)
    end

    it "branch manager C gets 404 on a request outside their scope" do
      sign_in manager_c
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

    it "branch manager C can approve their branch employee's request" do
      sign_in manager_c
      patch "/api/v1/employee_requests/#{request_c.id}/approve", as: :json
      expect(response).to have_http_status(:ok)
      expect(request_c.reload.status).to eq("approved")
    end

    it "branch manager C gets 404 trying to approve an out-of-scope request" do
      sign_in manager_c
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

    it "branch manager C can reject their branch employee's request" do
      sign_in manager_c
      patch "/api/v1/employee_requests/#{request_c.id}/reject", as: :json
      expect(response).to have_http_status(:ok)
      expect(request_c.reload.status).to eq("rejected")
    end
  end

  # ── EmployeeScope delegation regression ───────────────────────────────────
  #
  # These examples catch anyone accidentally re-introducing manager_id ownership
  # or a UserBranch membership check. Membership is shift-driven only.

  describe "EmployeeScope delegation regression" do
    it "branch manager sees branch employees via active shift assignment" do
      sign_in manager_a
      get "/api/v1/employee_requests", as: :json
      ids = response.parsed_body["data"].map { |r| r["id"] }
      expect(ids).to include(request_a.id)
    end

    it "an employee with no active assignment is not visible to any branch manager" do
      floating = create(:user, business: business)
      floating_req = create(:employee_request, :pending, user: floating)
      sign_in manager_a
      get "/api/v1/employee_requests", as: :json
      ids = response.parsed_body["data"].map { |r| r["id"] }
      expect(ids).not_to include(floating_req.id)
    end

    it "a branch manager cannot see another branch's employee request" do
      sign_in manager_a
      get "/api/v1/employee_requests/#{request_c.id}", as: :json
      expect(response).to have_http_status(:not_found)
    end
  end
end
