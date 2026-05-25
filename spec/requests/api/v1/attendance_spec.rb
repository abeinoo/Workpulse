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

  describe "API response includes timezone context" do
    it "includes work_date and timezone in check_in response" do
      post "/api/v1/attendance/check_in", params: { branch_id: branch.id }, as: :json
      json = response.parsed_body
      expect(json["data"]).to include("work_date", "timezone")
      expect(json["data"]["timezone"]).to eq(business.timezone)
    end

    context "when business is in Africa/Cairo (UTC+3)" do
      let(:cairo_business) { create(:business, timezone: "Africa/Cairo") }
      let(:cairo_branch)   { create(:branch, business: cairo_business) }
      let(:cairo_user)     { create(:user, business: cairo_business, allow_mobile_attendance: true) }

      before do
        create(:shift_assignment, user: cairo_user, branch: cairo_branch, shift: shift,
               effective_from: 1.month.ago.to_date)
        create(:user_branch, user: cairo_user, branch: cairo_branch)
        sign_in cairo_user
      end

      it "returns Africa/Cairo as the timezone" do
        post "/api/v1/attendance/check_in", params: { branch_id: cairo_branch.id }, as: :json
        expect(response.parsed_body.dig("data", "timezone")).to eq("Africa/Cairo")
      end

      it "sets work_date to the Cairo calendar date, not UTC date" do
        # Travel to 22:30 UTC = 00:30 Cairo next day (e.g. May 25 Cairo while UTC is still May 24)
        travel_to Time.utc(2026, 5, 24, 22, 30) do
          post "/api/v1/attendance/check_in", params: { branch_id: cairo_branch.id }, as: :json
          expect(response).to have_http_status(:created)
          work_date = response.parsed_body.dig("data", "work_date")
          expect(work_date).to eq("2026-05-25")
        end
      end

      # Regression: mobile showed 06:15 UTC instead of 09:15 Cairo because
      # the API returned raw UTC timestamps without a timezone offset.
      it "returns check_in_at with Cairo timezone offset, not bare UTC" do
        # 06:15 UTC = 09:15 Cairo (UTC+3)
        travel_to Time.utc(2026, 5, 25, 6, 15) do
          post "/api/v1/attendance/check_in", params: { branch_id: cairo_branch.id }, as: :json
          check_in_str = response.parsed_body.dig("data", "check_in_at")
          expect(check_in_str).not_to end_with("Z"), \
            "expected timezone-aware ISO8601 (e.g. +03:00) but got bare UTC: #{check_in_str}"
          parsed = Time.parse(check_in_str)
          expect(parsed.utc).to be_within(1.second).of(Time.utc(2026, 5, 25, 6, 15))
          expect(check_in_str).to include("+03:00").or include("+02:00")
        end
      end

      it "returns check_in_at displaying the local Cairo hour (09), not the UTC hour (06)" do
        travel_to Time.utc(2026, 5, 25, 6, 15) do
          post "/api/v1/attendance/check_in", params: { branch_id: cairo_branch.id }, as: :json
          check_in_str = response.parsed_body.dig("data", "check_in_at")
          # The ISO8601 string must start with the local date+time in Cairo, not UTC
          expect(check_in_str).to start_with("2026-05-25T09:15")
        end
      end

      it "returns check_out_at with Cairo timezone offset after check-out" do
        post "/api/v1/attendance/check_in", params: { branch_id: cairo_branch.id }, as: :json

        # Check out 8 hours later (14:15 UTC = 17:15 Cairo)
        travel_to Time.utc(2026, 5, 25, 14, 15) do
          post "/api/v1/attendance/check_out", params: { branch_id: cairo_branch.id }, as: :json
          check_out_str = response.parsed_body.dig("data", "check_out_at")
          expect(check_out_str).not_to end_with("Z")
          expect(check_out_str).to start_with("2026-05-25T17:15")
        end
      end
    end

    context "when business timezone is UTC" do
      let(:utc_business) { create(:business, timezone: "UTC") }
      let(:utc_branch)   { create(:branch, business: utc_business) }
      let(:utc_user)     { create(:user, business: utc_business, allow_mobile_attendance: true) }

      before do
        create(:shift_assignment, user: utc_user, branch: utc_branch, shift: shift,
               effective_from: 1.month.ago.to_date)
        create(:user_branch, user: utc_user, branch: utc_branch)
        sign_in utc_user
      end

      it "returns check_in_at with +00:00 offset for UTC business" do
        travel_to Time.utc(2026, 5, 25, 9, 0) do
          post "/api/v1/attendance/check_in", params: { branch_id: utc_branch.id }, as: :json
          check_in_str = response.parsed_body.dig("data", "check_in_at")
          expect(check_in_str).to include("+00:00").or include("Z")
          expect(check_in_str).to start_with("2026-05-25T09:00")
        end
      end
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
