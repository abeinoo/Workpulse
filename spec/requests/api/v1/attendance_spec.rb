require "rails_helper"

RSpec.describe "API V1 Attendance", type: :request do
  let(:business)    { create(:business) }
  let(:branch)      { create(:branch, business: business) }
  let(:user)        { create(:user, business: business) }
  let(:shift)       { create(:shift, :fixed_time, business: business) }

  before do
    create(:shift_assignment, user: user, branch: branch, shift: shift,
           effective_from: 1.month.ago.to_date)
    create(:user_branch, user: user, branch: branch)
    sign_in user
  end

  describe "POST /api/v1/attendance/check_in" do
    it "creates a record and returns 201" do
      expect {
        post "/api/v1/attendance/check_in", params: { branch_id: branch.id }, as: :json
      }.to change(AttendanceRecord, :count).by(1)
      expect(response).to have_http_status(:created)
    end

    it "returns error when already checked in" do
      post "/api/v1/attendance/check_in", params: { branch_id: branch.id }, as: :json
      post "/api/v1/attendance/check_in", params: { branch_id: branch.id }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "returns 401 when not authenticated" do
      sign_out user
      post "/api/v1/attendance/check_in", params: { branch_id: branch.id }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "POST /api/v1/attendance/check_out" do
    before do
      post "/api/v1/attendance/check_in", params: { branch_id: branch.id }, as: :json
    end

    it "updates the record and returns 200" do
      post "/api/v1/attendance/check_out", params: { branch_id: branch.id }, as: :json
      expect(response).to have_http_status(:ok)
    end

    it "sets check_out_at on the record" do
      post "/api/v1/attendance/check_out", params: { branch_id: branch.id }, as: :json
      expect(AttendanceRecord.last.check_out_at).to be_present
    end
  end

  describe "GET /api/v1/attendance/today" do
    it "returns nil record when not checked in" do
      get "/api/v1/attendance/today", as: :json
      expect(response).to have_http_status(:ok)
    end

    it "returns the current record after check-in" do
      post "/api/v1/attendance/check_in", params: { branch_id: branch.id }, as: :json
      get "/api/v1/attendance/today", as: :json
      json = response.parsed_body
      expect(json["data"]).to be_present
    end
  end
end
