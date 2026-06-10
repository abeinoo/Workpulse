require "rails_helper"

RSpec.describe "API V1 Employee Requests", type: :request do
  let(:business)  { create(:business) }
  let(:branch)    { create(:branch, business: business) }
  let(:manager)   { create(:user, :branch_manager, business: business) }
  let(:employee)  { create(:user, business: business) }
  let(:shift)     { create(:shift, :fixed_time, business: business) }

  before do
    # Make `manager` the branch_manager of `branch` and assign the employee there
    # (shift-driven membership).
    branch.update_column(:branch_manager_id, manager.id)
    create(:shift_assignment, user: employee, branch: branch, shift: shift)
  end

  # ---------------------------------------------------------------------------
  # GET /api/v1/employee_requests
  # ---------------------------------------------------------------------------
  describe "GET /api/v1/employee_requests" do
    before { sign_in employee }

    let!(:my_request)    { create(:employee_request, user: employee) }
    let!(:other_request) { create(:employee_request) }

    it "returns 200" do
      get "/api/v1/employee_requests", as: :json
      expect(response).to have_http_status(:ok)
    end

    it "returns only the employee's own requests" do
      get "/api/v1/employee_requests", as: :json
      ids = response.parsed_body["data"].map { |r| r["id"] }
      expect(ids).to include(my_request.id)
      expect(ids).not_to include(other_request.id)
    end

    it "returns 401 when not authenticated" do
      sign_out employee
      get "/api/v1/employee_requests", as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/v1/employee_requests
  # ---------------------------------------------------------------------------
  describe "POST /api/v1/employee_requests" do
    before { sign_in employee }

    let(:valid_params) do
      {
        employee_request: {
          request_type:       "late_permission",
          requested_for_date: Date.tomorrow.to_s,
          reason:             "Medical appointment",
          duration_minutes:   30
        }
      }
    end

    it "creates a new request and returns 201" do
      expect {
        post "/api/v1/employee_requests", params: valid_params, as: :json
      }.to change(EmployeeRequest, :count).by(1)
      expect(response).to have_http_status(:created)
    end

    it "sets status to pending by default" do
      post "/api/v1/employee_requests", params: valid_params, as: :json
      expect(EmployeeRequest.last.status).to eq("pending")
    end

    it "returns 422 when request_type is missing" do
      post "/api/v1/employee_requests",
           params: { employee_request: { reason: "test" } },
           as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    context "salary_advance request" do
      let(:advance_params) do
        {
          employee_request: {
            request_type:       "salary_advance",
            requested_for_date: Date.tomorrow.to_s,
            reason:             "Emergency",
            amount:             1500
          }
        }
      end

      it "creates a salary advance request" do
        expect {
          post "/api/v1/employee_requests", params: advance_params, as: :json
        }.to change(EmployeeRequest, :count).by(1)
        expect(EmployeeRequest.last.request_type).to eq("salary_advance")
        expect(EmployeeRequest.last.amount).to eq(1500.0)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # GET /api/v1/employee_requests/:id
  # ---------------------------------------------------------------------------
  describe "GET /api/v1/employee_requests/:id" do
    let!(:my_request) { create(:employee_request, user: employee) }

    before { sign_in employee }

    it "returns the request details" do
      get "/api/v1/employee_requests/#{my_request.id}", as: :json
      expect(response).to have_http_status(:ok)
      json = response.parsed_body
      expect(json["data"]["id"]).to eq(my_request.id)
    end

    it "returns 404 for another employee's request" do
      other_request = create(:employee_request)
      get "/api/v1/employee_requests/#{other_request.id}", as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/v1/employee_requests/:id/approve
  # ---------------------------------------------------------------------------
  describe "POST /api/v1/employee_requests/:id/approve" do
    let!(:pending_request) { create(:employee_request, :late_permission, user: employee) }

    before { sign_in manager }

    it "approves the request and returns 200" do
      patch "/api/v1/employee_requests/#{pending_request.id}/approve",
            params: { response_note: "Approved by manager" },
            as: :json
      expect(response).to have_http_status(:ok)
      expect(pending_request.reload.status).to eq("approved")
    end

    it "approves a salary_advance request but does NOT yet create an Advance (requires accountant pay action)" do
      advance_request = create(:employee_request, :salary_advance, :pending,
                               user: employee, amount: 2000)
      expect {
        patch "/api/v1/employee_requests/#{advance_request.id}/approve", as: :json
      }.not_to change(Advance, :count)
      expect(advance_request.reload.status).to eq("approved")
    end

    it "denies employee from approving requests" do
      sign_out manager
      sign_in employee
      patch "/api/v1/employee_requests/#{pending_request.id}/approve", as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "returns error when request is already approved" do
      pending_request.update!(status: "approved", reviewed_by: manager, reviewed_at: Time.current)
      patch "/api/v1/employee_requests/#{pending_request.id}/approve", as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  # ---------------------------------------------------------------------------
  # POST /api/v1/employee_requests/:id/reject
  # ---------------------------------------------------------------------------
  describe "POST /api/v1/employee_requests/:id/reject" do
    let!(:pending_request) { create(:employee_request, :late_permission, user: employee) }

    before { sign_in manager }

    it "rejects the request and returns 200" do
      patch "/api/v1/employee_requests/#{pending_request.id}/reject",
            params: { response_note: "Cannot accommodate at this time" },
            as: :json
      expect(response).to have_http_status(:ok)
      expect(pending_request.reload.status).to eq("rejected")
    end

    it "denies employee from rejecting requests" do
      sign_out manager
      sign_in employee
      patch "/api/v1/employee_requests/#{pending_request.id}/reject", as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end
end
