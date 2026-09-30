require "rails_helper"

# Structured request log line (config/initializers/api_request_logging.rb).
RSpec.describe "API v1 request tracing", type: :request do
  let(:business) { create(:business) }
  let(:user)     { create(:user, business: business, email: "trace@example.com", phone_number: "+966500000001") }

  let(:log_output) { StringIO.new }

  # Capture both the app logger and Action Controller's own request logging
  # ("Parameters: {…}"), so the PII assertions cover everything written.
  around do |example|
    original_rails, original_controller = Rails.logger, ActionController::Base.logger
    Rails.logger = ActionController::Base.logger = ActiveSupport::Logger.new(log_output)
    example.run
  ensure
    Rails.logger = original_rails
    ActionController::Base.logger = original_controller
  end

  def api_log_lines
    log_output.string.lines.filter_map do |line|
      JSON.parse(line) if line.include?('"event":"api.request"')
    rescue JSON::ParserError
      nil
    end
  end

  it "emits one api.request line correlated by the X-Request-Id header" do
    sign_in user
    get "/api/v1/attendance/today", as: :json

    lines = api_log_lines
    expect(lines.size).to eq(1)
    expect(lines.first).to include(
      "request_id"  => response.headers["X-Request-Id"],
      "method"      => "GET",
      "path"        => "/api/v1/attendance/today",
      "controller"  => "Api::V1::AttendanceController",
      "action"      => "today",
      "status"      => 200,
      "user_id"     => user.id,
      "business_id" => business.id
    )
    expect(lines.first["duration_ms"]).to be_a(Numeric)
  end

  it "honours a client-supplied X-Request-Id" do
    sign_in user
    get "/api/v1/attendance/today", as: :json, headers: { "X-Request-Id" => "client-req-123" }
    expect(response.headers["X-Request-Id"]).to eq("client-req-123")
    expect(api_log_lines.first["request_id"]).to eq("client-req-123")
  end

  it "never logs credentials or personal identifiers from the login request" do
    post "/api/v1/auth/login", params: { login: "trace@example.com", password: "secret-pass-1" }, as: :json
    expect(log_output.string).not_to include("secret-pass-1")
    expect(log_output.string).not_to include("trace@example.com")
    expect(api_log_lines.first).to include("path" => "/api/v1/auth/login", "status" => 401)
  end

  it "strips the query string from the logged path" do
    sign_in user
    get "/api/v1/attendance_records?start_date=2026-09-01", as: :json
    expect(api_log_lines.first["path"]).to eq("/api/v1/attendance_records")
  end

  it "identifies the device (not a user) for biometric punches" do
    device = create(:biometric_device, business: business)
    post "/api/v1/attendance/punch", params: { employee_id: "nobody", timestamp: Time.current.iso8601 },
                                     headers: { "Authorization" => "Bearer #{device.token}" }, as: :json
    expect(api_log_lines.first).to include("device_id" => device.id, "business_id" => business.id)
    expect(log_output.string).not_to include(device.token)
  end

  it "does not tag web (non-API) requests" do
    sign_in user
    get "/", headers: { "Accept" => "text/html" }
    expect(api_log_lines).to be_empty
  end
end
