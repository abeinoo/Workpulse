require "rails_helper"

RSpec.describe "AttendanceRecords", type: :request do
  let(:business) { create(:business, timezone: "Asia/Riyadh") }
  let(:branch)   { create(:branch, business: business) }
  let(:owner)    { create(:user, :owner, business: business) }

  before { sign_in owner }

  describe "GET /attendance_records (source filter)" do
    let(:shift) { create(:shift, :fixed_time, business: business) }
    let!(:mobile_record) do
      create(:attendance_record, :checked_out, business: business,
             branch: branch, check_in_source: "mobile", shift: shift)
    end
    let!(:biometric_record) do
      create(:attendance_record, :checked_out, business: business,
             branch: branch, check_in_source: "biometric_device", shift: shift)
    end

    it "returns all records when no source filter applied" do
      get attendance_records_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(mobile_record.user.full_name)
      expect(response.body).to include(biometric_record.user.full_name)
    end

    it "filters to only mobile records" do
      get attendance_records_path, params: { source: "mobile" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(mobile_record.user.full_name)
      expect(response.body).not_to include(biometric_record.user.full_name)
    end

    it "filters to only biometric_device records" do
      get attendance_records_path, params: { source: "biometric_device" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(biometric_record.user.full_name)
      expect(response.body).not_to include(mobile_record.user.full_name)
    end

    it "returns no records for a source with no matches" do
      get attendance_records_path, params: { source: "import" }
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(mobile_record.user.full_name)
      expect(response.body).not_to include(biometric_record.user.full_name)
    end
  end

  describe "locale persistence across login" do
    it "unauthenticated locale switch persists in session" do
      sign_out owner
      patch set_locale_path, params: { locale: "ar" }
      expect(session[:locale]).to eq("ar")
    end

    it "locale switch for authenticated user updates both session and user record" do
      patch set_locale_path, params: { locale: "ar" }
      expect(session[:locale]).to eq("ar")
      expect(owner.reload.preferred_locale).to eq("ar")
    end
  end
end
