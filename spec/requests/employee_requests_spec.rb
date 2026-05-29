require "rails_helper"

RSpec.describe "EmployeeRequests", type: :request do
  let(:business)  { create(:business, timezone: "Asia/Riyadh") }
  let(:branch)    { create(:branch, business: business) }
  let(:employee)  { create(:user, business: business) }

  before { sign_in employee }

  # ──────────────────────────────────────────────────────────────
  # Punch Correction — creation
  # ──────────────────────────────────────────────────────────────
  describe "POST /employee_requests (punch_correction)" do
    let(:valid_params) do
      {
        employee_request: {
          request_type:       "punch_correction",
          correction_type:    "missing_check_out",
          proposed_time:      "17:00",
          requested_for_date: Date.yesterday.iso8601,
          reason:             "Forgot to clock out"
        }
      }
    end

    it "creates the request and redirects" do
      expect {
        post employee_requests_path, params: valid_params
      }.to change(EmployeeRequest, :count).by(1)

      expect(response).to redirect_to(employee_requests_path)
    end

    it "saves the correct attributes" do
      post employee_requests_path, params: valid_params
      req = EmployeeRequest.last
      expect(req.punch_correction?).to be true
      expect(req.correction_missing_check_out?).to be true
      expect(req.requested_for_date).to eq(Date.yesterday)
      expect(req.affects_payroll).to be false
    end

    it "saves proposed_time" do
      post employee_requests_path, params: valid_params
      expect(EmployeeRequest.last.proposed_time).to eq("17:00")
    end

    it "creates requests for all correction_type values" do
      EmployeeRequest::CORRECTION_TYPES.each do |ct|
        post employee_requests_path, params: {
          employee_request: valid_params[:employee_request].merge(correction_type: ct)
        }
        expect(response).to redirect_to(employee_requests_path), "#{ct} should succeed"
      end
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Punch Correction — validation errors
  # ──────────────────────────────────────────────────────────────
  describe "POST /employee_requests (punch_correction) — validation errors" do
    it "re-renders the form when correction_type is missing" do
      post employee_requests_path, params: {
        employee_request: {
          request_type:       "punch_correction",
          correction_type:    "",
          proposed_time:      "17:00",
          requested_for_date: Date.yesterday.iso8601,
          reason:             "Forgot to clock out"
        }
      }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(I18n.t("requests.new.title"))
    end

    it "re-renders the form when proposed_time is missing" do
      post employee_requests_path, params: {
        employee_request: {
          request_type:       "punch_correction",
          correction_type:    "missing_check_out",
          proposed_time:      "",
          requested_for_date: Date.yesterday.iso8601,
          reason:             "Forgot to clock out"
        }
      }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "re-renders the form when reason is missing" do
      post employee_requests_path, params: {
        employee_request: {
          request_type:       "punch_correction",
          correction_type:    "missing_check_out",
          requested_for_date: Date.yesterday.iso8601,
          reason:             ""
        }
      }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "re-renders the form when date is missing" do
      post employee_requests_path, params: {
        employee_request: {
          request_type:       "punch_correction",
          correction_type:    "missing_check_out",
          requested_for_date: "",
          reason:             "Forgot to clock out"
        }
      }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Dashboard link pre-filling the form
  # ──────────────────────────────────────────────────────────────
  describe "GET /employee_requests/new — dashboard pre-fill" do
    it "pre-fills request_type, date, and correction_type from query params" do
      get new_employee_request_path,
          params: {
            request_type:       "punch_correction",
            requested_for_date: Date.yesterday.iso8601,
            correction_type:    "missing_check_out"
          }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("punch_correction")
      expect(response.body).to include(Date.yesterday.iso8601)
      expect(response.body).to include("missing_check_out")
    end

    it "ignores unknown request_type values" do
      get new_employee_request_path, params: { request_type: "unknown_type" }
      expect(response).to have_http_status(:ok)
      # form renders without error
    end

    it "ignores unknown correction_type values" do
      get new_employee_request_path,
          params: { request_type: "punch_correction", correction_type: "invalid_value" }
      expect(response).to have_http_status(:ok)
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Locale — English
  # ──────────────────────────────────────────────────────────────
  describe "GET /employee_requests/new — English locale" do
    around { |ex| I18n.with_locale(:en) { ex.run } }

    it "shows Punch Correction as a request type option" do
      get new_employee_request_path
      expect(response.body).to include(I18n.t("requests.types.punch_correction", locale: :en))
    end

    it "shows all correction type options" do
      EmployeeRequest::CORRECTION_TYPES.each do |ct|
        expect(I18n.t("requests.correction_types.#{ct}", locale: :en)).to be_present
      end
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Locale — Arabic
  # ──────────────────────────────────────────────────────────────
  describe "Arabic locale translations" do
    it "has Arabic translation for punch_correction type" do
      expect(I18n.t("requests.types.punch_correction", locale: :ar)).to eq("طلب تعديل بصمة")
    end

    it "has Arabic translations for all correction types" do
      EmployeeRequest::CORRECTION_TYPES.each do |ct|
        translation = I18n.t("requests.correction_types.#{ct}", locale: :ar)
        expect(translation).not_to include("translation missing"), "Missing AR translation for #{ct}"
      end
    end

    it "has Arabic translation for the dashboard banner title" do
      expect(I18n.t("dashboard.missing_checkout.title", locale: :ar)).to eq("يبدو أنك نسيت تسجيل الانصراف أمس.")
    end

    it "has Arabic translation for the dashboard banner CTA" do
      expect(I18n.t("dashboard.missing_checkout.cta", locale: :ar)).to eq("طلب تعديل بصمة")
    end

    it "renders the form in Arabic when user has Arabic locale" do
      employee.update!(preferred_locale: "ar")
      get new_employee_request_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("طلب تعديل بصمة")
    end
  end
end
