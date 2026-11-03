require "rails_helper"

# Device administration: choosing the device's branch, and surfacing devices
# that have none (their punches are logged without a branch).
RSpec.describe "Admin: biometric device branch", type: :request do
  let(:business)   { create(:business) }
  let!(:owner)     { create(:user, :owner, business: business) }
  let!(:branch)    { create(:branch, business: business, name: "Downtown") }
  let(:new_branch) { create(:branch, business: business, name: "Uptown") }

  before { sign_in owner }

  it "assigns a branch on create" do
    post admin_biometric_devices_path, params: { biometric_device: { name: "Door", branch_id: branch.id } }

    expect(BiometricDevice.find_by!(name: "Door").branch).to eq(branch)
  end

  it "moves a device to another branch without touching its past punch logs" do
    device = create(:biometric_device, business: business, branch: branch)
    log    = create(:biometric_punch_log, business: business, biometric_device: device, branch: branch)

    patch admin_biometric_device_path(device), params: { biometric_device: { branch_id: new_branch.id } }

    expect(device.reload.branch).to eq(new_branch)
    expect(log.reload.branch).to eq(branch)
  end

  it "refuses a branch of another business" do
    device = create(:biometric_device, business: business, branch: branch)

    patch admin_biometric_device_path(device), params: { biometric_device: { branch_id: create(:branch).id } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(device.reload.branch).to eq(branch)
  end

  it "refuses moving a device to an inactive branch" do
    device = create(:biometric_device, business: business, branch: branch)
    closed = create(:branch, :inactive, business: business, name: "Closed")

    patch admin_biometric_device_path(device), params: { biometric_device: { branch_id: closed.id } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(device.reload.branch).to eq(branch)
  end

  it "offers active branches and keeps a deactivated current branch selectable" do
    closed = create(:branch, :inactive, business: business, name: "Closed")
    create(:branch, :inactive, business: business, name: "Elsewhere")
    device = create(:biometric_device, business: business, branch: branch)
    device.update_column(:branch_id, closed.id)

    get edit_admin_biometric_device_path(device)

    expect(response.body).to include("Downtown")
    expect(response.body).to include(I18n.t("admin.biometric_devices.form.branch_inactive_option", name: "Closed"))
    expect(response.body).not_to include("Elsewhere")
  end

  it "warns about devices with no branch on the index and the device page" do
    unassigned = create(:biometric_device, business: business, name: "Old door", branch: nil)
    create(:biometric_device, business: business, branch: branch)

    get admin_biometric_devices_path
    expect(response.body).to include(I18n.t("admin.biometric_devices.index.unassigned_warning", count: 1))
    expect(response.body).to include(I18n.t("admin.biometric_devices.no_branch"))

    get admin_biometric_device_path(unassigned)
    expect(response.body).to include(I18n.t("admin.biometric_devices.show.unassigned_warning"))
  end

  it "shows no warning when every device has a branch" do
    create(:biometric_device, business: business, branch: branch)

    get admin_biometric_devices_path

    expect(response.body).not_to include('data-testid="devices-unassigned-warning"')
  end
end
