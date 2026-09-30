require "rails_helper"

# Characterization: locks the CURRENT /api/v1 authentication contract.
# See docs/api/authentication.md. Do not change expectations here to make a
# refactor pass — a change in these results is a contract change.
RSpec.describe "API v1 characterization — authentication", type: :request do
  let(:business) { create(:business) }
  let!(:user)    { create(:user, business: business, email: "staff@example.com") }

  describe "POST /api/v1/auth/login" do
    it "accepts a top-level JSON body (wrapped into `session` by wrap_parameters) and returns the user payload" do
      post "/api/v1/auth/login", params: { login: "staff@example.com", password: "password123" }, as: :json

      expect_legacy_success
      expect(api_data.keys).to match_array(%w[
        id first_name last_name email phone_number role permissions
        manages_area manages_branch business_id self_service checkin_branch_ids
      ])
      expect(api_data["self_service"].keys).to match_array(%w[
        can_create_requests can_view_own_attendance can_view_own_payroll can_check_in
      ])
      expect(api_data["role"]).to eq("staff")
      expect(api_data["permissions"]).to eq([])
    end

    it "also accepts an explicit `session` key" do
      post "/api/v1/auth/login", params: { session: { login: "staff@example.com", password: "password123" } }, as: :json
      expect_legacy_success
    end

    it "authenticates by setting the Devise session cookie (no token is issued)" do
      post "/api/v1/auth/login", params: { login: "staff@example.com", password: "password123" }, as: :json

      expect(response.headers["Set-Cookie"].to_s).to include("session")
      expect(api_data.keys.grep(/token/)).to be_empty

      get "/api/v1/attendance/today", as: :json
      expect_legacy_success
    end

    it "never serializes password or token material" do
      post "/api/v1/auth/login", params: { login: "staff@example.com", password: "password123" }, as: :json
      expect(response.body).not_to include("encrypted_password", "reset_password_token", "password123")
    end

    it "returns 401 in the legacy error envelope for a wrong password" do
      post "/api/v1/auth/login", params: { login: "staff@example.com", password: "wrong" }, as: :json
      expect_legacy_error(:unauthorized, message: "Invalid credentials")
    end

    it "returns the same 401 for an unknown login (no user enumeration)" do
      post "/api/v1/auth/login", params: { login: "nobody@example.com", password: "password123" }, as: :json
      expect_legacy_error(:unauthorized, message: "Invalid credentials")
    end

    it "returns 401 for an inactive user with the correct password" do
      user.update_column(:active, false)
      post "/api/v1/auth/login", params: { login: "staff@example.com", password: "password123" }, as: :json
      expect_legacy_error(:unauthorized, message: "Invalid credentials")
    end

    it "returns 400 (Rails ParameterMissing) when no credentials are sent" do
      post "/api/v1/auth/login", params: {}, as: :json
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "DELETE /api/v1/auth/logout" do
    it "signs out and returns the legacy success envelope" do
      sign_in user
      delete "/api/v1/auth/logout", as: :json

      expect_legacy_success
      expect(api_data).to eq("message" => "Logged out successfully")

      get "/api/v1/attendance/today", as: :json
      expect_devise_unauthenticated
    end

    it "returns the Devise 401 when not signed in" do
      delete "/api/v1/auth/logout", as: :json
      expect_devise_unauthenticated
    end
  end

  describe "unauthenticated access to a protected endpoint" do
    it "returns the Devise failure-app 401 for JSON requests" do
      get "/api/v1/employee_requests", as: :json
      expect_devise_unauthenticated
    end

    it "redirects (302) to the web sign-in page for non-JSON requests" do
      get "/api/v1/employee_requests"
      expect(response).to have_http_status(:found)
      expect(response.location).to include("/users/sign_in")
    end

    it "rejects a session belonging to a since-deactivated user with 401" do
      sign_in user
      user.update_column(:active, false)
      get "/api/v1/employee_requests", as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "CSRF" do
    # Known gap, documented in docs/api/authentication.md: /api/v1 skips CSRF
    # verification while authenticating with the web session cookie.
    it "does not require an authenticity token for cookie-authenticated API writes (current behaviour)" do
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      sign_in user
      delete "/api/v1/auth/logout", as: :json
      expect_legacy_success
    ensure
      ActionController::Base.allow_forgery_protection = original
    end
  end

  describe "CORS" do
    it "sends no CORS headers (the API is not exposed cross-origin)" do
      sign_in user
      get "/api/v1/attendance/today", as: :json, headers: { "Origin" => "https://evil.example" }
      expect(response.headers.keys.grep(/access-control/i)).to be_empty
    end
  end
end
