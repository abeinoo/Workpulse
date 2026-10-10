require "rails_helper"

# End-to-end account activation through the administrator's invitation link,
# exercised the way a browser does it: the link is copied from the admin
# employee page, opened, and the sign-up form (with the token from its hidden
# field) is submitted. The employee's phone is stored in Egyptian national
# (01…) form.
RSpec.describe "Account activation (sign-up)", type: :request do
  let(:business) { create(:business) }
  let(:hr_user)  { api_user_with(business, :view_employees, :manage_employees, scopes: { "manage_employees" => "business" }) }
  let!(:pending) { create(:user, :phone_only, :unregistered, business: business, phone_number: "01012345678") }

  let(:password) { "claim12345" }

  def html = Nokogiri::HTML(response.body)
  def t_html(key) = ERB::Util.html_escape(I18n.t(key))

  # The invitation URL exactly as the admin page renders it in the copy box.
  def invitation_url_from_admin_page(employee = pending)
    sign_in hr_user
    get admin_user_path(employee)
    expect(response).to have_http_status(:ok)
    url = html.at_css("input[readonly][value*='invitation=']")&.[]("value")
    sign_out hr_user
    url
  end

  # Opens the link like a browser and returns the token the form will submit.
  def open_invitation(url)
    uri = URI(url)
    get "#{uri.path}?#{uri.query}"
    expect(response).to have_http_status(:ok)
    html.at_css("form input[name='user[invitation_token]']")&.[]("value")
  end

  def submit_form(login:, token:, password: self.password)
    post user_registration_path,
         params: { user: { login: login, password: password, password_confirmation: password, invitation_token: token } }
  end

  def activated?(user = pending) = user.reload.encrypted_password.present?

  # ── The reproduced failure: reaching sign-up without the invitation link ──
  describe "without the invitation link (sign-in page → Create account)" do
    it "shows a clear blocking state with the next step instead of a form that cannot succeed" do
      get new_user_session_path
      create_account = html.css("a").find { |a| a.text.strip == I18n.t("auth.links.create_account") }
      get create_account["href"]

      expect(response).to have_http_status(:ok)
      expect(html.at_css("#invitation-required")).to be_present
      expect(response.body).to include(t_html("auth.register.invitation_required"))
      expect(html.at_css("form[action='#{user_registration_path}']")).to be_nil
      expect(response.body).not_to include(t_html("auth.register.invalid_invitation"))
    end

    it "answers a submission without a token with the missing-link message, not 'invalid or expired'" do
      submit_form(login: "01012345678", token: "")
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(t_html("auth.register.invitation_required"))
      expect(response.body).not_to include(t_html("auth.register.invalid_invitation"))
      expect(activated?).to be(false)
    end
  end

  # ── A fresh invitation from the admin page ───────────────────────────────
  describe "with a fresh invitation copied from the admin employee page" do
    it "carries the token in the URL parameter the sign-up page reads, unchanged" do
      url = invitation_url_from_admin_page
      expect(URI(url).path).to eq(new_user_registration_path)
      link_token = Rack::Utils.parse_query(URI(url).query).fetch("invitation")

      expect(open_invitation(url)).to eq(link_token)
      # Generation (admin page) and lookup (registration) agree on purpose and scope.
      expect(User.find_by_token_for(:account_claim, link_token)).to eq(pending)
    end

    [ "01012345678", "+201012345678", "201012345678", "00201012345678", "٠١٠١٢٣٤٥٦٧٨" ].each do |format|
      it "activates the intended employee when the phone is entered as #{format.inspect}" do
        token = open_invitation(invitation_url_from_admin_page)

        expect { submit_form(login: format, token: token) }.not_to change(User, :count)
        expect(response).to redirect_to(root_path)
        pending.reload
        expect(pending.valid_password?(password)).to be(true)
        expect(pending.phone_number).to eq("01012345678")
      end
    end

    it "explains a phone mismatch and keeps the typed value and the invitation on the form" do
      token = open_invitation(invitation_url_from_admin_page)
      submit_form(login: "+201012345679", token: token)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(t_html("auth.register.login_mismatch"))
      expect(html.at_css("input[name='user[login]']")["value"]).to eq("+201012345679")
      expect(html.at_css("input[name='user[invitation_token]']")["value"]).to eq(token)
      expect(activated?).to be(false)
    end

    it "reports a password problem as such, keeping the invitation usable" do
      token = open_invitation(invitation_url_from_admin_page)
      submit_form(login: "01012345678", token: token, password: "short")

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).not_to include(t_html("auth.register.invalid_invitation"))
      expect(response.body).not_to include(t_html("auth.register.login_mismatch"))
      expect(html.at_css("input[name='user[invitation_token]']")["value"]).to eq(token)

      submit_form(login: "01012345678", token: token)
      expect(response).to redirect_to(root_path)
    end

    it "cannot activate a different employee, even with that employee's phone" do
      other = create(:user, :phone_only, :unregistered, business: business, phone_number: "01112345678")
      token = open_invitation(invitation_url_from_admin_page(pending))

      submit_form(login: "01112345678", token: token)
      expect(response.body).to include(t_html("auth.register.login_mismatch"))
      expect(activated?(other)).to be(false)
      expect(activated?(pending)).to be(false)
    end
  end

  # ── Refused invitations: one generic message ─────────────────────────────
  describe "refused invitations" do
    def expect_generic_refusal
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(t_html("auth.register.invalid_invitation"))
      expect(activated?).to be(false)
    end

    it "refuses an invitation older than 7 days" do
      token = open_invitation(invitation_url_from_admin_page)
      travel 7.days + 1.minute do
        submit_form(login: "01012345678", token: token)
      end
      expect_generic_refusal
    end

    it "still accepts an invitation just inside the 7 days" do
      token = open_invitation(invitation_url_from_admin_page)
      travel 7.days - 1.minute do
        submit_form(login: "01012345678", token: token)
      end
      expect(response).to redirect_to(root_path)
    end

    it "refuses reuse once the account is activated" do
      token = open_invitation(invitation_url_from_admin_page)
      submit_form(login: "01012345678", token: token)
      expect(response).to redirect_to(root_path)
      sign_out pending

      submit_form(login: "01012345678", token: token, password: "another123")
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(t_html("auth.register.invalid_invitation"))
      expect(pending.reload.valid_password?(password)).to be(true)
    end

    it "refuses a deactivated account, and the admin page stops offering a link" do
      token = open_invitation(invitation_url_from_admin_page)
      pending.update!(active: false)

      submit_form(login: "01012345678", token: token)
      expect_generic_refusal
      expect(invitation_url_from_admin_page).to be_nil
    end

    [ "not-a-token", "%%%--@@@", "eyJfcmFpbHMiOnt9fQ==--0000" ].each do |bad|
      it "refuses a malformed token (#{bad.inspect})" do
        submit_form(login: "01012345678", token: bad)
        expect_generic_refusal
      end
    end

    it "refuses a truncated link (e.g. cut off when pasted)" do
      token = open_invitation(invitation_url_from_admin_page)
      submit_form(login: "01012345678", token: token[0...-6])
      expect_generic_refusal
    end
  end

  # ── Replacing an expired link through the admin page ─────────────────────
  it "activates with a fresh link from the admin page after the old one expired" do
    old_token = open_invitation(invitation_url_from_admin_page)

    travel 8.days do
      submit_form(login: "01012345678", token: old_token)
      expect(response.body).to include(t_html("auth.register.invalid_invitation"))

      # The administrator reopens the employee page: a new link is issued.
      new_token = open_invitation(invitation_url_from_admin_page)
      expect(new_token).not_to eq(old_token)
      submit_form(login: "+201012345678", token: new_token)
      expect(response).to redirect_to(root_path)
    end
    expect(activated?).to be(true)
  end
end
