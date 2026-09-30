require "rails_helper"

# Characterization: employee self-service endpoints (attendance, requests,
# advances) — the current contract a mobile client depends on.
RSpec.describe "API v1 characterization — employee self-service", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }
  let(:employee) { create(:user, business: business, allow_mobile_attendance: true) }

  let(:attendance_keys) do
    %w[
      id work_date date status check_in_latitude check_in_longitude
      check_out_latitude check_out_longitude worked_minutes late_minutes
      early_leave_minutes check_in_at check_out_at timezone
    ]
  end

  before do
    create(:shift_assignment, user: employee, branch: branch, shift: shift, effective_from: 3.months.ago.to_date)
    sign_in employee
  end

  describe "attendance" do
    it "GET /attendance/today returns data: null before any check-in" do
      get "/api/v1/attendance/today", as: :json
      expect_legacy_success
      expect(api_json["data"]).to be_nil
    end

    it "POST /attendance/check_in returns 201 with the attendance fields" do
      post "/api/v1/attendance/check_in", params: { branch_id: branch.id }, as: :json
      expect_legacy_success(:created)
      expect(api_data.keys).to match_array(attendance_keys)
      expect(api_data["timezone"]).to eq(business.timezone)
    end

    it "POST /attendance/check_in returns 404 'Branch not found' without an assigned branch" do
      post "/api/v1/attendance/check_in", params: {}, as: :json
      expect_legacy_error(:not_found, message: "Branch not found")
    end

    it "POST /attendance/check_in returns 404 for a branch the user is not assigned to (branch_id from params is not trusted)" do
      other_branch = create(:branch, business: business)
      post "/api/v1/attendance/check_in", params: { branch_id: other_branch.id }, as: :json
      expect_legacy_error(:not_found, message: "Branch not found")
    end

    it "POST /attendance/check_in returns 404 for another business's branch" do
      foreign_branch = create(:branch)
      post "/api/v1/attendance/check_in", params: { branch_id: foreign_branch.id }, as: :json
      expect_legacy_error(:not_found, message: "Branch not found")
    end

    it "POST /attendance/check_in returns 422 in the legacy envelope when already checked in" do
      post "/api/v1/attendance/check_in", params: { branch_id: branch.id }, as: :json
      post "/api/v1/attendance/check_in", params: { branch_id: branch.id }, as: :json
      expect_legacy_error(:unprocessable_content)
    end

    it "POST /attendance/check_in returns 403 when mobile attendance is not allowed" do
      employee.update_column(:allow_mobile_attendance, false)
      post "/api/v1/attendance/check_in", params: { branch_id: branch.id }, as: :json
      expect_legacy_error(:forbidden, message: I18n.t("api.punch.mobile_attendance_not_allowed"))
    end

    it "POST /attendance/check_out returns 200 with the attendance fields" do
      post "/api/v1/attendance/check_in", params: { branch_id: branch.id }, as: :json
      post "/api/v1/attendance/check_out", params: { branch_id: branch.id }, as: :json
      expect_legacy_success
      expect(api_data.keys).to match_array(attendance_keys)
    end

    it "POST /attendance/check_out returns 404 for another business's branch" do
      post "/api/v1/attendance/check_out", params: { branch_id: create(:branch).id }, as: :json
      expect_legacy_error(:not_found, message: "Branch not found")
    end
  end

  describe "employee requests" do
    let(:request_keys) do
      %w[
        id request_type status requested_for_date amount reason response_note
        affects_payroll reviewed_at created_at user_id reviewed_by_id
      ]
    end

    let!(:own_request)   { create(:employee_request, :late_permission, user: employee) }
    let!(:other_request) { create(:employee_request, :late_permission, user: create(:user, business: business)) }

    it "GET /employee_requests returns an unpaginated array of the employee's own requests" do
      get "/api/v1/employee_requests", as: :json
      expect_legacy_success
      expect(api_data).to be_an(Array)
      expect(api_data.map { |r| r["id"] }).to eq([ own_request.id ])
      expect(api_data.first.keys).to match_array(request_keys)
    end

    it "GET /employee_requests ignores page/per_page (no pagination today)" do
      create_list(:employee_request, 2, :early_leave, user: employee)
      get "/api/v1/employee_requests", params: { page: 1, per_page: 1 }, as: :json
      expect(api_data.size).to eq(3)
    end

    it "GET /employee_requests/:id returns 404 for a coworker's request" do
      get "/api/v1/employee_requests/#{other_request.id}", as: :json
      expect_legacy_error(:not_found, message: "Record not found")
    end

    it "POST /employee_requests returns 422 with full_messages on validation failure" do
      post "/api/v1/employee_requests", params: { employee_request: { request_type: "late_permission" } }, as: :json
      expect_legacy_error(:unprocessable_content, message: "Failed to submit request")
      expect(api_json["errors"]).not_to be_empty
    end

    it "POST /employee_requests creates the request for current_user (user_id from params is not permitted)" do
      coworker = create(:user, business: business)
      post "/api/v1/employee_requests",
           params: { employee_request: { request_type: "late_permission", requested_for_date: Date.current + 1,
                                         reason: "Medical appointment", duration_minutes: 30, user_id: coworker.id } },
           as: :json

      if response.status == 201
        expect_legacy_success(:created)
        expect(api_data["user_id"]).to eq(employee.id)
      else
        # Creation can be refused by business rules; it must never be attributed to the coworker.
        expect(EmployeeRequest.where(user: coworker).count).to eq(0)
      end
    end

    it "PATCH /employee_requests/:id/approve returns 403 for the requester (self-approval blocked)" do
      patch "/api/v1/employee_requests/#{own_request.id}/approve", as: :json
      expect_legacy_error(:forbidden, message: "Forbidden")
    end

    it "PATCH /employee_requests/:id/cancel cancels an own pending request" do
      patch "/api/v1/employee_requests/#{own_request.id}/cancel", params: { cancellation_reason: "No longer needed" }, as: :json
      expect_legacy_success
      expect(api_data["status"]).to eq("cancelled")
    end
  end

  describe "advances" do
    let(:advance_keys) { %w[id user_id total_amount remaining_amount status issued_at repaid_amount] }

    let!(:own_advance)   { create(:advance, business: business, user: employee) }
    let!(:other_advance) { create(:advance, business: business) }

    it "GET /advances returns only the employee's own advances with a stable field set" do
      get "/api/v1/advances", as: :json
      expect(response).to have_http_status(:ok)
      expect(api_json["success"]).to be(true)
      expect(api_data.map { |a| a["id"] }).to eq([ own_advance.id ])
      expect(api_data.first.keys).to match_array(advance_keys)
      expect(api_data.first["total_amount"]).to eq("1000.0")
    end

    it "GET /advances/:id returns 404 for another employee's advance" do
      get "/api/v1/advances/#{other_advance.id}", as: :json
      expect(response).to have_http_status(:not_found)
      expect(api_json["success"]).to be(false)
      expect(api_json["message"]).to eq("Record not found")
    end
  end
end
