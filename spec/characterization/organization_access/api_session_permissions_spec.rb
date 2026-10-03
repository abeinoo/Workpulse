require "rails_helper"

# Characterization (PermissionRole pilot, Step 1 gaps G2, G3) — the
# `permissions` field of the API login payload (Api::V1::SessionsController
# #user_payload: `user.permission_role&.permissions || []`). The no-role case is
# locked in spec/requests/api/v1/characterization/authentication_spec.rb. Mobile
# clients consume this field; any change here is an API contract change.
RSpec.describe "Characterization: API login permissions", type: :request do
  let(:business) { create(:business) }
  let(:payload_keys) do
    %w[id first_name last_name email phone_number role permissions
       manages_area manages_branch business_id self_service checkin_branch_ids]
  end

  def login(email)
    post "/api/v1/auth/login", params: { login: email, password: "password123" }, as: :json
  end

  it "G2: a role holder receives exactly the role's stored permissions, as role 'staff'" do
    holder = api_user_with(business, :view_attendance, :view_shifts, :view_employees,
                           scopes: { "view_attendance" => "branch" }, email: "holder@example.com")
    login("holder@example.com")

    expect_legacy_success
    expect(api_data.keys).to match_array(payload_keys) # scopes are not exposed
    expect(api_data["role"]).to eq("staff")
    expect(api_data["permissions"]).to eq(holder.permission_role.permissions)
    expect(api_data["permissions"]).to eq(%w[view_attendance view_shifts view_employees])
  end

  it "G3: the owner receives role 'owner' and an EMPTY permissions list (owner has no role)" do
    create(:user, :owner, business: business, email: "owner@example.com")
    login("owner@example.com")

    expect_legacy_success
    expect(api_data.keys).to match_array(payload_keys)
    expect(api_data["role"]).to eq("owner")
    expect(api_data["permissions"]).to eq([])
  end
end
