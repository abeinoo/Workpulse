require "rails_helper"

# End-to-end self-service registration at /users/sign_up, the way a browser
# does it: the employee's account is pre-created by an administrator (no
# password), the employee opens the sign-up page from the sign-in page, enters
# the registered mobile number and a password, and is signed in. No invitation
# link (removed 2026-11-15; phone-only is an accepted risk, see OA-S6).
RSpec.describe "Self-service registration (sign-up)", type: :request do
  let(:business) { create(:business) }
  let(:hr_user)  { api_user_with(business, :view_employees, :manage_employees, scopes: { "manage_employees" => "business" }) }
  let!(:pending) { create(:user, :phone_only, :unregistered, business: business, phone_number: "01012345678") }

  let(:password) { "claim12345" }

  def html = Nokogiri::HTML(response.body)
  def t_html(key) = ERB::Util.html_escape(I18n.t(key))

  def submit_form(phone:, password: self.password, confirmation: password, ip: "10.0.0.1")
    post user_registration_path,
         params:  { user: { phone_number: phone, password: password, password_confirmation: confirmation } },
         headers: { "REMOTE_ADDR" => ip }
  end

  def activated?(user = pending) = user.reload.encrypted_password.present?

  def signed_in?
    get root_path
    !response.redirect? || response.location != new_user_session_url
  end

  describe "the sign-up page" do
    it "is reached from the sign-in page and offers mobile number, password and confirmation" do
      get new_user_session_path
      create_account = html.css("a").find { |a| a.text.strip == I18n.t("auth.links.create_account") }
      get create_account["href"]

      expect(response).to have_http_status(:ok)
      form = html.at_css("form[action='#{user_registration_path}']")
      expect(form).to be_present
      expect(form.css("input").map { _1["name"] }.compact)
        .to include("user[phone_number]", "user[password]", "user[password_confirmation]")
      expect(form.at_css("input[name='user[invitation_token]']")).to be_nil
      expect(form.at_css("input[name='user[login]']")).to be_nil
      expect(response.body).to include(t_html("auth.fields.mobile_number"))
      expect(form.at_css("input[name='user[phone_number]']")["placeholder"]).to eq(I18n.t("auth.fields.mobile_number_placeholder"))
      expect(response.body).to include(t_html("auth.register.submit"))
      expect(html.css("a").map(&:text).map(&:strip)).to include(I18n.t("auth.links.sign_in"))
    end

    it "shows no invitation or blocking state and ignores an old ?invitation= parameter" do
      get new_user_registration_path(invitation: "old-token")
      expect(response).to have_http_status(:ok)
      expect(html.at_css("#invitation-required")).to be_nil
      expect(response.body).not_to include("old-token")
      expect(html.at_css("form[action='#{user_registration_path}']")).to be_present
    end
  end

  describe "successful registration" do
    [ "01012345678", "+201012345678", "201012345678", "00201012345678", "٠١٠١٢٣٤٥٦٧٨" ].each do |format|
      it "activates the existing employee entered as #{format.inspect} and signs them in" do
        expect { submit_form(phone: format) }.not_to change(User, :count)
        expect(response).to redirect_to(root_path)
        expect(flash[:notice]).to eq(I18n.t("flash.welcome_registered"))
        expect(signed_in?).to be(true)
        pending.reload
        expect(pending.valid_password?(password)).to be(true)
        expect(pending.phone_number).to eq("01012345678")
      end
    end

    it "records the audit entry with the request IP" do
      submit_form(phone: "01012345678", ip: "10.9.8.7")
      entry = AuditLog.find_by!(action: "account_registered")
      expect(entry).to have_attributes(actor_id: pending.id, auditable_id: pending.id, business_id: business.id)
      expect(entry.metadata["ip_address"]).to eq("10.9.8.7")
    end

    it "lets the employee sign in normally afterwards with the chosen password" do
      submit_form(phone: "01012345678")
      sign_out pending
      post user_session_path, params: { user: { login: "+201012345678", password: password } }
      expect(response).to redirect_to(root_path)
      expect(signed_in?).to be(true)
    end

    it "switches the admin employee page from Pending registration to Registered, with no invitation link" do
      sign_in hr_user
      get admin_user_path(pending)
      expect(response.body).to include(t_html("admin.users.pending_registration"))
      expect(response.body).not_to include("invitation=")
      sign_out hr_user

      submit_form(phone: "01012345678")
      sign_out pending

      sign_in hr_user
      get admin_user_path(pending)
      expect(response.body).to include(t_html("admin.users.registered"))
      expect(response.body).not_to include(t_html("admin.users.pending_registration"))
    end
  end

  describe "refused registrations" do
    def expect_generic_refusal(user = pending)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(t_html("auth.register.not_available"))
      expect(activated?(user)).to be(false)
      expect(signed_in?).to be(false)
    end

    it "refuses an unknown number with the generic message and keeps the typed value" do
      submit_form(phone: "+201099999999")
      expect(html.at_css("input[name='user[phone_number]']")["value"]).to eq("+201099999999")
      expect_generic_refusal
    end

    it "keeps Arabic-Indic digits as typed on the redisplayed form" do
      submit_form(phone: "٠١٠٩٩٩٩٩٩٩٩")
      expect(html.at_css("input[name='user[phone_number]']")["value"]).to eq("٠١٠٩٩٩٩٩٩٩٩")
    end

    it "refuses an inactive account" do
      pending.update!(active: false)
      submit_form(phone: "01012345678")
      expect_generic_refusal
    end

    it "refuses an already registered account and keeps its password" do
      registered = create(:user, :phone_only, business: business, phone_number: "01112345678")
      submit_form(phone: "01112345678")
      expect(response.body).to include(t_html("auth.register.not_available"))
      expect(registered.reload.valid_password?("password123")).to be(true)
      expect(signed_in?).to be(false)
    end

    it "refuses a second registration of the same account" do
      submit_form(phone: "01012345678")
      expect(response).to redirect_to(root_path)
      sign_out pending

      submit_form(phone: "01012345678", password: "another123")
      expect(response.body).to include(t_html("auth.register.not_available"))
      expect(pending.reload.valid_password?(password)).to be(true)
    end

    it "reports a short password as such, then succeeds once corrected" do
      submit_form(phone: "01012345678", password: "short")
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).not_to include(t_html("auth.register.not_available"))
      expect(activated?).to be(false)

      submit_form(phone: "01012345678")
      expect(response).to redirect_to(root_path)
    end

    it "reports a confirmation mismatch as such" do
      submit_form(phone: "01012345678", confirmation: "different123")
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(ERB::Util.html_escape(User.human_attribute_name(:password_confirmation)))
      expect(activated?).to be(false)
    end

    it "refuses when the audit entry cannot be written (nothing committed, not signed in)" do
      fail_audit_writes!(:account_registered)
      submit_form(phone: "01012345678")
      expect_generic_refusal
    end

    it "never reveals employee details in a refusal" do
      business.update!(name: "Nile Salon Group")
      pending.update!(first_name: "Mona", last_name: "Saleh")
      create(:user, :phone_only, business: business, phone_number: "01112345678", first_name: "Zainab", last_name: "Hamdy")

      [ [ "01112345678", {} ], [ "01012345678", { password: "short" } ],
        [ "01012345678", { confirmation: "different123" } ] ].each do |phone, options|
        submit_form(phone: phone, **options)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).not_to include("Zainab", "Hamdy", "Mona", "Saleh", "Nile Salon Group")
      end
    end
  end

  describe "existing accounts (regression)" do
    let!(:registered) { create(:user, :phone_only, business: business, phone_number: "01212345678") }

    it "still sign in with their existing password, unchanged by the new flow" do
      digest = registered.encrypted_password
      post user_session_path, params: { user: { login: "01212345678", password: "password123" } }
      expect(response).to redirect_to(root_path)
      expect(registered.reload.encrypted_password).to eq(digest)
    end

    it "keep their role and permissions" do
      admin = api_user_with(business, :view_employees, :manage_employees, scopes: { "manage_employees" => "business" })
      submit_form(phone: "01012345678")
      sign_out pending

      sign_in admin
      get admin_users_path
      expect(response).to have_http_status(:ok)
      expect(admin.reload.can?(:manage_employees)).to be(true)
    end
  end
end
