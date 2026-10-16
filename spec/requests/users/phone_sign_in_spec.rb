require "rails_helper"

# Phone-number sign-in through the web form and the mobile API, for an
# Egyptian employee whose phone is stored in national (01…) form.
RSpec.describe "Phone-number sign-in", type: :request do
  let(:business) { create(:business) }
  let!(:employee) { create(:user, :phone_only, business: business, phone_number: "01012345678") }

  equivalent_formats = [ "01012345678", "+201012345678", "201012345678", "00201012345678", "٠١٠١٢٣٤٥٦٧٨" ]

  describe "web sign-in" do
    def sign_in_with(login, password = "password123")
      post user_session_path, params: { user: { login: login, password: password } }
    end

    def signed_in?
      get root_path
      !response.redirect? || response.location != new_user_session_url
    end

    equivalent_formats.each do |format|
      it "signs in with the phone typed as #{format.inspect}" do
        sign_in_with(format)
        expect(response).to redirect_to(root_path)
        expect(signed_in?).to be(true)
      end
    end

    it "keeps the stored phone number unchanged" do
      sign_in_with("+201012345678")
      expect(employee.reload.phone_number).to eq("01012345678")
    end

    it "refuses a genuinely different number" do
      sign_in_with("+201012345679")
      expect(response).to have_http_status(:unprocessable_content)
      expect(signed_in?).to be(false)
    end

    it "refuses an equivalent format with the wrong password" do
      sign_in_with("+201012345678", "wrong-password")
      expect(response).to have_http_status(:unprocessable_content)
      expect(signed_in?).to be(false)
    end

    it "still signs in by email" do
      create(:user, business: business, email: "mona@example.com", phone_number: nil)
      sign_in_with("MONA@example.com")
      expect(response).to redirect_to(root_path)
    end

    it "refuses an inactive account in any format" do
      employee.update!(active: false)
      [ "01012345678", "+201012345678" ].each do |format|
        sign_in_with(format)
        expect(signed_in?).to be(false)
      end
    end

    it "refuses an account still pending registration" do
      create(:user, :phone_only, :unregistered, business: business, phone_number: "01112345678")
      sign_in_with("+201112345678", "")
      expect(signed_in?).to be(false)
    end
  end

  describe "API sign-in" do
    def api_login(login, password = "password123")
      post "/api/v1/auth/login", params: { login: login, password: password }, as: :json
    end

    equivalent_formats.each do |format|
      it "signs in with the phone typed as #{format.inspect}" do
        api_login(format)
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.dig("data", "id")).to eq(employee.id)
        expect(response.parsed_body.dig("data", "phone_number")).to eq("01012345678")
      end
    end

    it "refuses a genuinely different number" do
      api_login("+201012345679")
      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses an equivalent format with the wrong password" do
      api_login("+201012345678", "wrong-password")
      expect(response).to have_http_status(:unauthorized)
    end

    it "still signs in by email" do
      create(:user, business: business, email: "mona@example.com", phone_number: nil)
      api_login("mona@example.com")
      expect(response).to have_http_status(:ok)
    end

    it "refuses an inactive account in any format" do
      employee.update!(active: false)
      [ "01012345678", "+201012345678" ].each do |format|
        api_login(format)
        expect(response).to have_http_status(:unauthorized)
      end
    end

    it "keeps non-Egyptian numbers to their own international forms" do
      saudi = create(:user, :phone_only, business: business, phone_number: "+966501234567")
      api_login("00966501234567")
      expect(response.parsed_body.dig("data", "id")).to eq(saudi.id)

      api_login("0501234567")
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
