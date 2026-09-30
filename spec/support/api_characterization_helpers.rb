# Helpers for API request specs — especially the characterization suite in
# spec/requests/api/v1/characterization/, which locks the CURRENT /api/v1
# contract before any API-foundation change (see docs/api/baseline.md).
module ApiCharacterizationHelpers
  LEGACY_SUCCESS_KEYS   = %w[success data].freeze
  LEGACY_ERROR_KEYS     = %w[success message errors].freeze
  STANDARD_SUCCESS_KEYS = %w[success data meta request_id].freeze
  STANDARD_ERROR_KEYS   = %w[success error request_id message errors].freeze

  def api_json
    response.parsed_body
  end

  def api_data
    api_json.fetch("data")
  end

  # Legacy ApiResponder success envelope: exactly { success: true, data: … }.
  def expect_legacy_success(status = :ok)
    expect(response).to have_http_status(status)
    expect(api_json.keys).to match_array(LEGACY_SUCCESS_KEYS)
    expect(api_json["success"]).to be(true)
  end

  # Legacy ApiResponder error envelope: exactly { success: false, message:, errors: [] }.
  def expect_legacy_error(status, message: nil)
    expect(response).to have_http_status(status)
    expect(api_json.keys).to match_array(LEGACY_ERROR_KEYS)
    expect(api_json["success"]).to be(false)
    expect(api_json["errors"]).to be_an(Array)
    expect(api_json["message"]).to eq(message) if message
  end

  # Devise failure-app response for a JSON request without a valid session.
  def expect_devise_unauthenticated
    expect(response).to have_http_status(:unauthorized)
    expect(api_json.keys).to eq([ "error" ])
  end

  # Standard contract (docs/api/conventions.md).
  def expect_standard_success(status = :ok)
    expect(response).to have_http_status(status)
    expect(api_json.keys).to match_array(STANDARD_SUCCESS_KEYS)
    expect(api_json["success"]).to be(true)
    expect(api_json["request_id"]).to eq(response.headers["X-Request-Id"])
  end

  def expect_standard_error(status, code:)
    expect(response).to have_http_status(status)
    expect(api_json.keys).to match_array(STANDARD_ERROR_KEYS)
    expect(api_json["success"]).to be(false)
    expect(api_json.dig("error", "code")).to eq(code)
    expect(api_json.dig("error", "message")).to be_present
    expect(api_json.dig("error", "details")).to be_an(Array)
    expect(api_json["request_id"]).to eq(response.headers["X-Request-Id"])
  end

  # A user holding exactly `permissions` through a fresh PermissionRole.
  # Prefer this over the :owner trait when a spec needs several privileged
  # users in one business (the last :owner created silently wins).
  def api_user_with(business, *permissions, scopes: {}, **attributes)
    user = create(:user, business: business, **attributes)
    return user if permissions.empty?

    role = create(:permission_role, business: business,
                  permissions: permissions.flatten.map(&:to_s), permission_scopes: scopes)
    user.update_column(:permission_role_id, role.id)
    user.reload
  end
end

RSpec.configure do |config|
  config.include ApiCharacterizationHelpers, type: :request
end
