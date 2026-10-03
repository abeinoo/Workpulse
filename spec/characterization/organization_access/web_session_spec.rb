require "rails_helper"

# Characterization — Organization & Access web session contract (Devise cookie
# session). Captures CURRENT behaviour as a safety net for the future
# migration; it is not a statement of desired behaviour.
# API session behaviour is characterized in
# spec/requests/api/v1/characterization/authentication_spec.rb.
RSpec.describe "Characterization: Organization & Access web session", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business, email: "owner@example.com") }
  let(:staff)    { create(:user, business: business, email: "staff@example.com", phone_number: "+966501112233") }

  def sign_in_with(login, password = "password123")
    post user_session_path, params: { user: { login: login, password: password } }
  end

  describe "unauthenticated requests" do
    it "redirects HTML requests for protected pages to the sign-in page" do
      get root_path
      expect(response).to redirect_to(new_user_session_path)
    end

    it "renders the sign-in page" do
      get new_user_session_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "login" do
    it "signs in with an email (case-insensitive) and keeps the session across requests" do
      staff
      sign_in_with("STAFF@example.com")
      expect(response).to redirect_to(root_path)

      get root_path
      expect(response).to have_http_status(:ok)
    end

    it "signs in with a phone number" do
      staff
      sign_in_with("+966501112233")
      expect(response).to redirect_to(root_path)
    end

    it "sends users who can manage settings to the admin area after sign-in" do
      sign_in_with("owner@example.com")
      expect(response).to redirect_to(admin_root_path)
    end

    it "rejects a wrong password without signing in" do
      staff
      sign_in_with("staff@example.com", "wrong-password")
      expect(response).to have_http_status(:unprocessable_content)
      get root_path
      expect(response).to redirect_to(new_user_session_path)
    end

    it "rejects an inactive account with the correct password" do
      staff.update!(active: false)
      sign_in_with("staff@example.com")
      get root_path
      expect(response).to redirect_to(new_user_session_path)
    end

    it "rejects an account that has no password yet (pending registration)" do
      pending_user = create(:user, :unregistered, business: business, email: "pending@example.com")
      sign_in_with("pending@example.com", "")
      get root_path
      expect(response).to redirect_to(new_user_session_path)
      expect(pending_user.reload.encrypted_password).to be_blank
    end
  end

  describe "logout" do
    it "ends the session" do
      sign_in staff
      delete destroy_user_session_path
      expect(response).to redirect_to(root_path)

      get root_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe "session invalidation" do
    it "signs out a live session once the account is deactivated" do
      sign_in staff
      get root_path
      expect(response).to have_http_status(:ok)

      staff.update!(active: false)
      get root_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe "authorization failure response (web)" do
    it "redirects to root with the not-authorized alert" do
      sign_in staff
      get admin_permission_roles_path
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
    end
  end

  describe "request context" do
    it "renders in the business default locale when the user has no preference" do
      business.update!(default_locale: "ar")
      staff.update_column(:preferred_locale, nil)
      sign_in staff
      get root_path
      expect(response.body).to include('lang="ar"', 'dir="rtl"')
    end

    it "runs the request in the business timezone" do
      business.update!(timezone: "Asia/Riyadh")
      zone_seen = nil
      allow_any_instance_of(DashboardController).to receive(:index).and_wrap_original do |original, *args|
        zone_seen = Time.zone.name
        original.call(*args)
      end
      sign_in staff
      get root_path
      expect(zone_seen).to eq("Asia/Riyadh")
    end
  end
end
