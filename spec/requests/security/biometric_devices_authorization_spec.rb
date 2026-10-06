require "rails_helper"

# SEC-M2-1: Admin::BiometricDevicesController called no policy, so anyone past
# Admin::BaseController's broad gate (view_employees, view_attendance,
# view_payroll …) could read, regenerate or create device tokens — and a token
# authenticates POST /api/v1/attendance/punch for any employee of the business.
# Every action now requires manage_devices (BiometricDevicePolicy) within the
# device's business.
RSpec.describe "Security: biometric device administration", type: :request do
  let(:business)      { create(:business) }
  let(:other)         { create(:business) }
  let!(:owner)        { create(:user, :owner, business: business) }
  let!(:device)       { create(:biometric_device, business: business, name: "Front door") }
  let!(:foreign)      { create(:biometric_device, business: other, name: "Foreign door") }
  let(:device_params) { { biometric_device: { name: "New device", location_note: "Lobby", active: "1" } } }

  # Holds every permission that opens Admin::BaseController for a default
  # branch/area manager, but not manage_devices.
  let(:admin_gate_user) { api_user_with(business, :view_employees, :view_attendance, :view_payroll) }
  let(:device_manager)  { api_user_with(business, :manage_devices) }

  def expect_denied
    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
  end

  describe "without manage_devices" do
    before { sign_in admin_gate_user }

    it "cannot list devices" do
      get admin_biometric_devices_path
      expect_denied
    end

    it "cannot view a device or its token" do
      get admin_biometric_device_path(device)
      expect_denied
      expect(response.body).not_to include(device.token)
    end

    it "cannot open the new or edit forms" do
      get new_admin_biometric_device_path
      expect_denied
      get edit_admin_biometric_device_path(device)
      expect_denied
    end

    it "cannot create a device" do
      expect { post admin_biometric_devices_path, params: device_params }.not_to change(BiometricDevice, :count)
      expect_denied
    end

    it "cannot update a device" do
      patch admin_biometric_device_path(device), params: { biometric_device: { name: "Renamed", active: "0" } }
      expect_denied
      expect(device.reload).to have_attributes(name: "Front door", active: true)
    end

    it "cannot delete a device" do
      expect { delete admin_biometric_device_path(device) }.not_to change(BiometricDevice, :count)
      expect_denied
    end

    it "cannot regenerate a device token" do
      expect { patch regenerate_token_admin_biometric_device_path(device) }.not_to(change { device.reload.token })
      expect_denied
    end
  end

  describe "with manage_devices (same business)" do
    before { sign_in device_manager }

    it "lists only the business's devices" do
      get admin_biometric_devices_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Front door")
      expect(response.body).not_to include("Foreign door")
    end

    it "views a device and its token" do
      get admin_biometric_device_path(device)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(device.token)
    end

    it "creates, updates, regenerates and deletes a device" do
      expect { post admin_biometric_devices_path, params: device_params }.to change(business.biometric_devices, :count).by(1)
      created = business.biometric_devices.find_by!(name: "New device")
      expect(response).to redirect_to(admin_biometric_device_path(created))

      patch admin_biometric_device_path(created), params: { biometric_device: { name: "Renamed" } }
      expect(created.reload.name).to eq("Renamed")

      expect { patch regenerate_token_admin_biometric_device_path(created) }.to(change { created.reload.token })

      expect { delete admin_biometric_device_path(created) }.to change(BiometricDevice, :count).by(-1)
      expect(response).to redirect_to(admin_biometric_devices_path)
    end
  end

  # One request per example: the rescued 404 does not carry the signed-in
  # test session into a following request.
  describe "cross-business isolation" do
    before { sign_in device_manager }

    it "cannot view another business's device" do
      get admin_biometric_device_path(foreign)
      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include(foreign.token)
    end

    it "cannot update another business's device" do
      patch admin_biometric_device_path(foreign), params: { biometric_device: { name: "Hijacked" } }
      expect(response).to have_http_status(:not_found)
      expect(foreign.reload.name).to eq("Foreign door")
    end

    it "cannot regenerate another business's device token" do
      expect { patch regenerate_token_admin_biometric_device_path(foreign) }.not_to(change { foreign.reload.token })
      expect(response).to have_http_status(:not_found)
    end

    it "cannot delete another business's device" do
      expect { delete admin_biometric_device_path(foreign) }.not_to change(BiometricDevice, :count)
      expect(response).to have_http_status(:not_found)
    end
  end

  it "the owner keeps full access" do
    sign_in owner
    get admin_biometric_device_path(device)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(device.token)
  end
end
