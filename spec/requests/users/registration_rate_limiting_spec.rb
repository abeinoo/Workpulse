require "rails_helper"

# POST /users (self-service registration) rate limits
# (Users::RegistrationsController): 5 per IP + phone number and 20 per IP, each
# per 15 minutes. The test env uses a null cache store (no limits); swap in a
# real store here, as spec/requests/api/v1/standard_contract/rate_limiting_spec.rb does.
RSpec.describe "Self-service registration rate limiting", type: :request do
  let(:business) { create(:business) }
  let!(:pending) { create(:user, :phone_only, :unregistered, business: business, phone_number: "01012345678") }

  around do |example|
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original
  end

  def attempt(phone, password: "password123", confirmation: password, ip: "10.0.0.1")
    post user_registration_path,
         params:  { user: { phone_number: phone, password: password, password_confirmation: confirmation } },
         headers: { "REMOTE_ADDR" => ip }
  end

  def rate_limited?
    response.status == 429 && response.body.include?(ERB::Util.html_escape(I18n.t("auth.register.rate_limited")))
  end

  it "allows 5 attempts per phone number per IP, then refuses even a valid registration" do
    5.times { attempt("01012345678", password: "short") }
    expect(response).to have_http_status(:unprocessable_content)

    attempt("01012345678")
    expect(rate_limited?).to be(true)
    expect(pending.reload.encrypted_password).to be_blank
  end

  it "counts equivalent phone formats as one number" do
    formats = [ "01012345678", "+201012345678", "201012345678", "00201012345678", "٠١٠١٢٣٤٥٦٧٨" ]
    formats.each { |format| attempt(format, password: "short") }

    attempt("+20 101 234 5678")
    expect(rate_limited?).to be(true)
  end

  it "counts numbers independently (one employee's mistakes do not block a colleague)" do
    6.times { attempt("01099999999") }
    attempt("01012345678")
    expect(response).to redirect_to(root_path)
  end

  it "counts the same number independently per IP" do
    6.times { attempt("01012345678", password: "short", ip: "10.0.0.1") }
    attempt("01012345678", ip: "10.0.0.2")
    expect(response).to redirect_to(root_path)
  end

  it "caps attempts per IP at 20 across different numbers (sweeping is throttled)" do
    20.times { |i| attempt("0109#{i.to_s.rjust(7, '0')}") }
    expect(response).to have_http_status(:unprocessable_content)

    attempt("01012345678")
    expect(rate_limited?).to be(true)
    expect(pending.reload.encrypted_password).to be_blank

    attempt("01012345678", ip: "10.0.0.2")
    expect(response).to redirect_to(root_path)
  end

  it "answers the rate limit with the sign-up form and no account details" do
    6.times { attempt("01012345678", password: "short") }
    expect(response).to have_http_status(:too_many_requests)
    expect(Nokogiri::HTML(response.body).at_css("form[action='#{user_registration_path}']")).to be_present
    expect(response.body).not_to include(pending.first_name)
  end
end
