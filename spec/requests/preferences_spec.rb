require "rails_helper"

RSpec.describe "Preferences", type: :request do
  let(:business) { create(:business, default_locale: "ar") }
  let(:user)     { create(:user, business: business, preferred_locale: "ar") }

  before { sign_in user }

  describe "PATCH /preferences/locale" do
    context "switching to English" do
      it "saves the locale on the user record" do
        patch user_locale_path, params: { locale: "en" },
                                headers: { "Accept" => "application/json",
                                           "Content-Type" => "application/json" },
                                as: :json
        expect(response).to have_http_status(:ok)
        expect(user.reload.preferred_locale).to eq("en")
      end

      it "stores the new locale in the session" do
        patch user_locale_path, params: { locale: "en" }, as: :json
        expect(session[:locale]).to eq("en")
      end

      it "responds with HTML redirect when not JSON" do
        patch user_locale_path, params: { locale: "en" }
        expect(response).to redirect_to(root_path)
        expect(user.reload.preferred_locale).to eq("en")
      end
    end

    context "switching to Arabic" do
      let(:user) { create(:user, business: business, preferred_locale: "en") }

      it "saves Arabic locale and stores it in session" do
        patch user_locale_path, params: { locale: "ar" }, as: :json
        expect(user.reload.preferred_locale).to eq("ar")
        expect(session[:locale]).to eq("ar")
      end
    end

    context "with an unsupported locale" do
      it "does not update the user record" do
        expect {
          patch user_locale_path, params: { locale: "fr" }, as: :json
        }.not_to change { user.reload.preferred_locale }
      end
    end

    context "when not signed in" do
      before { sign_out user }

      it "redirects to sign in" do
        patch user_locale_path, params: { locale: "en" }, as: :json
        expect(response).to have_http_status(:unauthorized).or redirect_to(new_user_session_path)
      end
    end
  end

  describe "locale priority in set_locale" do
    context "user has a preferred_locale" do
      let(:user) { create(:user, business: business, preferred_locale: "en") }

      it "serves pages in the user's preferred locale even when business default differs" do
        get root_path
        expect(response.body).to include('lang="en"')
      end
    end

    context "user has no preferred_locale (falls back to business default)" do
      let(:user) { create(:user, business: business, preferred_locale: nil) }

      it "serves pages in the business default locale" do
        get root_path
        expect(response.body).to include('lang="ar"')
      end
    end

    context "after switching locale, next request uses the new preference" do
      it "persists across requests" do
        patch user_locale_path, params: { locale: "en" }, as: :json
        get root_path
        expect(response.body).to include('lang="en"')
      end
    end
  end

  describe "html lang and dir attributes" do
    context "when locale is English" do
      let(:user) { create(:user, business: business, preferred_locale: "en") }

      it "renders html with lang=en and dir=ltr" do
        get root_path
        expect(response.body).to include('lang="en"')
        expect(response.body).to include('dir="ltr"')
      end
    end

    context "when locale is Arabic" do
      let(:user) { create(:user, business: business, preferred_locale: "ar") }

      it "renders html with lang=ar and dir=rtl" do
        get root_path
        expect(response.body).to include('lang="ar"')
        expect(response.body).to include('dir="rtl"')
      end
    end

    context "when locale is Arabic, meta tags carry the locale info" do
      let(:user) { create(:user, business: business, preferred_locale: "ar") }

      it "includes app-locale and app-dir meta tags" do
        get root_path
        expect(response.body).to include('name="app-locale" content="ar"')
        expect(response.body).to include('name="app-dir" content="rtl"')
      end
    end
  end
end
