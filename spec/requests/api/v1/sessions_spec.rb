require "rails_helper"

RSpec.describe "API V1 Sessions", type: :request do
  let(:business) { create(:business) }

  describe "POST /api/v1/auth/login" do
    context "with valid email credentials" do
      let!(:user) { create(:user, business: business, email: "ahmed@example.com") }

      it "returns 200 with user data" do
        post "/api/v1/auth/login", params: { login: "ahmed@example.com", password: "password123" },
             as: :json
        expect(response).to have_http_status(:ok)
        json = response.parsed_body
        expect(json["success"]).to be true
        expect(json["data"]).to be_present
      end

      it "includes user profile data" do
        post "/api/v1/auth/login", params: { login: "ahmed@example.com", password: "password123" },
             as: :json
        json = response.parsed_body
        expect(json["data"]["email"]).to eq("ahmed@example.com")
        expect(json["data"]["role"]).to be_present
      end
    end

    context "with valid phone credentials" do
      let!(:user) { create(:user, :phone_only, business: business, phone_number: "+966501234567") }

      it "returns 200" do
        post "/api/v1/auth/login", params: { login: "+966501234567", password: "password123" },
             as: :json
        expect(response).to have_http_status(:ok)
      end
    end

    context "with invalid password" do
      let!(:user) { create(:user, business: business, email: "user@example.com") }

      it "returns 401" do
        post "/api/v1/auth/login", params: { login: "user@example.com", password: "wrong" },
             as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "with unknown login" do
      it "returns 401" do
        post "/api/v1/auth/login", params: { login: "nobody@example.com", password: "password123" },
             as: :json
        expect(response).to have_http_status(:unauthorized)
      end
    end
  end

  describe "DELETE /api/v1/auth/logout" do
    let!(:user) { create(:user, business: business) }

    it "signs out and returns 200" do
      # First sign in to get a session
      post "/api/v1/auth/login", params: { login: user.email, password: "password123" }, as: :json
      token = response.parsed_body["token"]

      delete "/api/v1/auth/logout", headers: { "Authorization" => "Bearer #{token}" }
      expect(response).to have_http_status(:ok)
    end
  end
end
