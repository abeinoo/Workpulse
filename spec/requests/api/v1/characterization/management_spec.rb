require "rails_helper"

# Characterization: manager-facing scheduling / attendance / salary endpoints.
RSpec.describe "API v1 characterization — management endpoints", type: :request do
  let(:business)        { create(:business) }
  let(:branch)          { create(:branch, business: business) }
  let!(:owner)          { create(:user, :owner, business: business) }
  let(:employee)        { create(:user, business: business) }
  let(:shift)           { create(:shift, :fixed_time, business: business) }

  let(:other_business)  { create(:business) }
  let(:foreign_shift)   { create(:shift, :fixed_time, business: other_business) }
  let(:foreign_user)    { create(:user, business: other_business) }

  describe "shifts" do
    let(:shift_keys) { %w[id name shift_type start_time end_time required_hours active] }

    it "GET /shifts returns the business's active shifts as an unpaginated array" do
      shift
      foreign_shift
      sign_in owner
      get "/api/v1/shifts", as: :json
      expect_legacy_success
      expect(api_data.map { |s| s["id"] }).to eq([ shift.id ])
      expect(api_data.first.keys).to match_array(shift_keys)
    end

    it "GET /shifts is visible to a plain employee (index does not call authorize)" do
      shift
      sign_in employee
      get "/api/v1/shifts", as: :json
      expect_legacy_success
      expect(api_data.map { |s| s["id"] }).to eq([ shift.id ])
    end

    it "GET /shifts/:id includes penalty_rules (serialized as full model attributes)" do
      create(:penalty_rule, shift: shift)
      sign_in owner
      get "/api/v1/shifts/#{shift.id}", as: :json
      expect_legacy_success
      expect(api_data.keys).to match_array(shift_keys + [ "penalty_rules" ])
      expect(api_data["penalty_rules"].first.keys).to include("id", "shift_id", "created_at", "updated_at")
    end

    it "GET /shifts/:id returns 404 for another business's shift" do
      sign_in owner
      get "/api/v1/shifts/#{foreign_shift.id}", as: :json
      expect_legacy_error(:not_found, message: "Record not found")
    end

    it "POST /shifts returns 403 without manage_shifts" do
      sign_in employee
      post "/api/v1/shifts", params: { shift: { name: "Morning", shift_type: "fixed_time" } }, as: :json
      expect_legacy_error(:forbidden, message: "Forbidden")
    end

    it "POST /shifts returns 422 with full_messages on validation failure" do
      sign_in owner
      post "/api/v1/shifts", params: { shift: { name: "", shift_type: "fixed_time" } }, as: :json
      expect_legacy_error(:unprocessable_content, message: "Failed to create shift")
      expect(api_json["errors"]).not_to be_empty
    end

    it "POST /shifts creates in current_user's business (business_id from params is ignored)" do
      sign_in owner
      post "/api/v1/shifts",
           params: { shift: { name: "Evening", shift_type: "fixed_time", start_time: "13:00", end_time: "21:00",
                              business_id: other_business.id } },
           as: :json
      expect_legacy_success(:created)
      expect(Shift.find(api_data["id"]).business_id).to eq(business.id)
    end
  end

  describe "penalty rules" do
    it "GET /shifts/:shift_id/penalty_rules returns raw model attributes" do
      create(:penalty_rule, shift: shift)
      sign_in owner
      get "/api/v1/shifts/#{shift.id}/penalty_rules", as: :json
      expect_legacy_success
      expect(api_data.first.keys).to include("id", "shift_id", "rule_type", "threshold_minutes",
                                             "deduction_type", "deduction_value", "created_at", "updated_at")
    end

    it "returns 404 for another business's shift" do
      sign_in owner
      get "/api/v1/shifts/#{foreign_shift.id}/penalty_rules", as: :json
      expect_legacy_error(:not_found)
    end
  end

  describe "shift assignments" do
    let(:assignment_keys) do
      %w[id user_id shift_id shift_name branch_id branch_name effective_from effective_to]
    end

    it "GET /shift_assignments returns the scoped assignments with a stable field set" do
      create(:shift_assignment, user: employee, branch: branch, shift: shift)
      sign_in owner
      get "/api/v1/shift_assignments", as: :json
      expect_legacy_success
      expect(api_data.first.keys).to match_array(assignment_keys)
    end

    it "GET /shift_assignments/:id returns 404 for another business's assignment" do
      foreign = create(:shift_assignment, business: other_business)
      sign_in owner
      get "/api/v1/shift_assignments/#{foreign.id}", as: :json
      expect_legacy_error(:not_found)
    end

    it "POST /shift_assignments rejects a shift from another business" do
      sign_in owner
      post "/api/v1/shift_assignments",
           params: { shift_assignment: { user_id: employee.id, shift_id: foreign_shift.id, branch_id: branch.id,
                                         effective_from: Date.current } },
           as: :json
      expect_legacy_error(:unprocessable_content, message: "Branch or shift not found in this business")
    end

    it "POST /shift_assignments returns 403 without assign_shifts" do
      sign_in employee
      post "/api/v1/shift_assignments",
           params: { shift_assignment: { user_id: employee.id, shift_id: shift.id, branch_id: branch.id,
                                         effective_from: Date.current } },
           as: :json
      expect_legacy_error(:forbidden)
    end

    # S1 (docs/api/baseline.md) — fixed; full matrix in
    # spec/requests/api/v1/security/cross_business_authorization_spec.rb.
    it "POST /shift_assignments rejects a user from another business" do
      sign_in owner
      post "/api/v1/shift_assignments",
           params: { shift_assignment: { user_id: foreign_user.id, shift_id: shift.id, branch_id: branch.id,
                                         effective_from: Date.current } },
           as: :json
      expect_legacy_error(:unprocessable_content, message: "Employee not found in this business")
      expect(ShiftAssignment.where(user: foreign_user).count).to eq(0)
    end
  end

  describe "attendance records" do
    let(:record_keys) do
      %w[id user_id branch_id date status worked_minutes late_minutes early_leave_minutes check_in_at check_out_at]
    end
    let!(:record) { create(:attendance_record, :checked_out, business: business, user: employee, branch: branch) }

    it "GET /attendance_records returns an unpaginated array for the current month" do
      sign_in owner
      get "/api/v1/attendance_records", as: :json
      expect_legacy_success
      expect(api_data.map { |r| r["id"] }).to include(record.id)
      expect(api_data.first.keys).to match_array(record_keys)
    end

    it "GET /attendance_records silently falls back to the month on an unparseable date" do
      sign_in owner
      get "/api/v1/attendance_records", params: { start_date: "not-a-date" }, as: :json
      expect_legacy_success
    end

    it "GET /attendance_records/:id adds the adjustments list" do
      sign_in owner
      get "/api/v1/attendance_records/#{record.id}", as: :json
      expect_legacy_success
      expect(api_data.keys).to match_array(record_keys + [ "adjustments" ])
    end

    it "GET /attendance_records/:id returns 404 for another business's record" do
      foreign = create(:attendance_record, business: other_business)
      sign_in owner
      get "/api/v1/attendance_records/#{foreign.id}", as: :json
      expect_legacy_error(:not_found)
    end

    it "an employee only sees their own records" do
      create(:attendance_record, business: business, user: create(:user, business: business), branch: branch)
      sign_in employee
      get "/api/v1/attendance_records", as: :json
      expect(api_data.map { |r| r["user_id"] }.uniq).to eq([ employee.id ])
    end

    it "PATCH /attendance_records/:id returns 403 without manage_attendance" do
      sign_in employee
      patch "/api/v1/attendance_records/#{record.id}",
            params: { attendance_record: { reason: "fix" } }, as: :json
      expect_legacy_error(:forbidden)
    end
  end

  describe "salary profiles" do
    let(:profile_keys) { %w[id salary_type base_amount currency effective_from active] }
    let!(:profile)     { create(:salary_profile, user: employee) }

    it "GET /users/:user_id/salary_profiles returns the profile fields" do
      sign_in owner
      get "/api/v1/users/#{employee.id}/salary_profiles", as: :json
      expect_legacy_success
      expect(api_data.first.keys).to match_array(profile_keys)
    end

    it "returns 404 for a user of another business" do
      sign_in owner
      get "/api/v1/users/#{foreign_user.id}/salary_profiles", as: :json
      expect_legacy_error(:not_found)
    end

    it "does not expose another employee's salary to a plain employee" do
      sign_in create(:user, business: business)
      get "/api/v1/users/#{employee.id}/salary_profiles", as: :json
      expect(response.status).to be_in([ 403, 404 ])
      expect(response.body).not_to include(profile.base_amount.to_s)
    end
  end

  describe "routes declared without controllers" do
    # KNOWN DEFECT (docs/api/baseline.md → D2): routes.rb declares these
    # resources but no controllers exist. Locked here so they are not mistaken
    # for working endpoints.
    %w[/api/v1/businesses/1 /api/v1/branches /api/v1/users].each do |path|
      it "GET #{path} is not a working endpoint" do
        sign_in owner
        begin
          get path, as: :json
          expect(response).to have_http_status(:not_found)
        rescue ActionController::RoutingError, NameError
          # The missing controller constant surfaces as an exception in test.
        end
      end
    end
  end
end
