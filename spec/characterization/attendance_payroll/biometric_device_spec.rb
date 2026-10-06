require "rails_helper"

# Characterization (Milestone 2 Pilot 1, M1) — CURRENT BiometricDevice rules:
# model validations, token lifecycle, admin CRUD outcomes and how device state
# drives the device-token realm (POST /api/v1/attendance/punch).
# Authorization of every admin action (manage_devices, cross-business 404,
# owner) is in spec/requests/security/biometric_devices_authorization_spec.rb
# (SEC-M2-1); the punch API contract in
# spec/requests/api/v1/characterization/biometric_punch_spec.rb.
RSpec.describe "Characterization: biometric devices", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }

  describe "model" do
    it "generates a 43-character url-safe token on create, ignoring a supplied token" do
      device = create(:biometric_device, business: business, token: "chosen-token")

      expect(device.token).not_to eq("chosen-token")
      expect(device.token).to match(/\A[A-Za-z0-9_-]{43}\z/)
    end

    it "gives every device a different token, across businesses" do
      tokens = [ create(:biometric_device, business: business), create(:biometric_device, business: other) ].map(&:token)
      expect(tokens.uniq.size).to eq(2)
    end

    it "rejects a token already used by another device" do
      first  = create(:biometric_device, business: business)
      second = create(:biometric_device, business: other)

      expect(second.update(token: first.token)).to be(false)
      expect(second.errors[:token]).to be_present
    end

    it "regenerate_token! replaces and persists the token" do
      device = create(:biometric_device, business: business)
      old    = device.token

      device.regenerate_token!

      expect(device.reload.token).not_to eq(old)
      expect(device.token).to match(/\A[A-Za-z0-9_-]{43}\z/)
    end

    it "requires a name and a business" do
      expect(build(:biometric_device, business: business, name: "")).not_to be_valid
      expect(build(:biometric_device, business: nil)).not_to be_valid
    end

    it "keeps names unique per business, case-insensitively" do
      create(:biometric_device, business: business, name: "Front Door")

      duplicate = build(:biometric_device, business: business, name: "front door")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:name]).to be_present

      expect(build(:biometric_device, business: other, name: "Front Door")).to be_valid
    end

    it "is active by default; .active and .for_business filter" do
      active   = create(:biometric_device, business: business)
      inactive = create(:biometric_device, business: business, active: false)
      foreign  = create(:biometric_device, business: other)

      expect(BiometricDevice.new.active).to be(true)
      expect(BiometricDevice.active).to include(active, foreign)
      expect(BiometricDevice.active).not_to include(inactive)
      expect(BiometricDevice.for_business(business)).to contain_exactly(active, inactive)
    end

    it "keeps its punch logs when destroyed (logs are detached, not deleted)" do
      device = create(:biometric_device, business: business)
      log    = create(:biometric_punch_log, business: business, biometric_device: device)

      expect { device.destroy }.not_to change(BiometricPunchLog, :count)
      expect(log.reload.biometric_device_id).to be_nil
    end
  end

  describe "admin CRUD outcomes (manage_devices)" do
    let(:manager) { api_user_with(business, :manage_devices) }

    before { sign_in manager }

    it "creates a device in the actor's business with a generated token" do
      post admin_biometric_devices_path, params: { biometric_device: {
        name: "Gate", location_note: "North gate", active: "1", token: "chosen", business_id: other.id
      } }

      device = BiometricDevice.find_by!(name: "Gate")
      expect(response).to redirect_to(admin_biometric_device_path(device))
      expect(flash[:notice]).to eq(I18n.t("flash.biometric_device_created"))
      expect(device).to have_attributes(business_id: business.id, location_note: "North gate", active: true)
      expect(device.token).not_to eq("chosen")
    end

    it "re-renders the form with 422 for a blank or duplicate name" do
      create(:biometric_device, business: business, name: "Gate")

      expect { post admin_biometric_devices_path, params: { biometric_device: { name: "" } } }.not_to change(BiometricDevice, :count)
      expect(response).to have_http_status(:unprocessable_content)

      expect { post admin_biometric_devices_path, params: { biometric_device: { name: "GATE" } } }.not_to change(BiometricDevice, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "updates name, location and active flag but never the token" do
      device = create(:biometric_device, business: business, name: "Gate")
      token  = device.token

      patch admin_biometric_device_path(device), params: { biometric_device: {
        name: "Gate 2", location_note: "Moved", active: "0", token: "chosen"
      } }

      expect(response).to redirect_to(admin_biometric_device_path(device))
      expect(flash[:notice]).to eq(I18n.t("flash.biometric_device_updated"))
      expect(device.reload).to have_attributes(name: "Gate 2", location_note: "Moved", active: false, token: token)
    end

    it "re-renders the edit form with 422 for an invalid update" do
      device = create(:biometric_device, business: business, name: "Gate")

      patch admin_biometric_device_path(device), params: { biometric_device: { name: "" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(device.reload.name).to eq("Gate")
    end

    it "lists the business's devices ordered by name" do
      create(:biometric_device, business: business, name: "Zeta")
      create(:biometric_device, business: business, name: "Alpha")

      get admin_biometric_devices_path

      expect(response.body.index("Alpha")).to be < response.body.index("Zeta")
    end

    it "deletes a device with a notice, keeping its logs" do
      device = create(:biometric_device, business: business)
      log    = create(:biometric_punch_log, business: business, biometric_device: device)

      delete admin_biometric_device_path(device)

      expect(response).to redirect_to(admin_biometric_devices_path)
      expect(flash[:notice]).to eq(I18n.t("flash.biometric_device_deleted"))
      expect(BiometricDevice.exists?(device.id)).to be(false)
      expect(log.reload.biometric_device_id).to be_nil
    end
  end

  describe "device state in the punch API (device-token realm)" do
    let(:branch)   { create(:branch, business: business) }
    let(:employee) { create(:user, business: business, employee_code: "E-1", allow_biometric_attendance: true) }
    let(:manager)  { api_user_with(business, :manage_devices) }
    let!(:device)  { create(:biometric_device, business: business) }

    before do
      create(:shift_assignment, user: employee, branch: branch, shift: create(:shift, :fixed_time, business: business),
                                effective_from: 1.month.ago.to_date)
    end

    def punch_with(token, at: Time.current)
      post "/api/v1/attendance/punch", params: { employee_id: "E-1", timestamp: at.iso8601 },
                                       headers: { "Authorization" => "Bearer #{token}" }, as: :json
    end

    it "rejects an unknown token with 401" do
      punch_with("not-a-device-token")
      expect(response).to have_http_status(:unauthorized)
    end

    it "touches last_seen_at on a successful authentication only" do
      expect(device.last_seen_at).to be_nil

      punch_with(device.token)
      expect(device.reload.last_seen_at).to be_present

      device.update_columns(active: false, last_seen_at: nil)
      punch_with(device.token)
      expect(device.reload.last_seen_at).to be_nil
    end

    it "stops accepting a token once the device is deactivated in the admin" do
      sign_in manager
      patch admin_biometric_device_path(device), params: { biometric_device: { active: "0" } }

      punch_with(device.reload.token)
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects the old token and accepts the new one after regeneration" do
      old_token = device.token
      sign_in manager
      patch regenerate_token_admin_biometric_device_path(device)
      expect(flash[:notice]).to eq(I18n.t("flash.token_regenerated"))

      punch_with(old_token)
      expect(response).to have_http_status(:unauthorized)

      punch_with(device.reload.token, at: 2.minutes.from_now)
      expect(response).to have_http_status(:ok)
    end

    it "rejects the token of a deleted device" do
      token = device.token
      device.destroy

      punch_with(token)
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
