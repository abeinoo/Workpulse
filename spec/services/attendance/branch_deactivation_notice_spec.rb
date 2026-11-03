require "rails_helper"

# The Attendance & Payroll implementation of the deactivation notice: the
# biometric devices registered to the branch, by name, inactive ones marked,
# with their count. Read-only.
RSpec.describe Attendance::BranchDeactivationNotice do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:other)    { create(:branch, business: business) }

  it "returns no notice when no device is registered to the branch" do
    create(:biometric_device, business: business, branch: other)
    create(:biometric_device, business: business, branch: nil)

    expect(described_class.notices_for(branch: branch)).to eq([])
  end

  it "lists the branch's devices by name, marks inactive ones, and counts them" do
    create(:biometric_device, business: business, branch: branch, name: "Front door")
    create(:biometric_device, business: business, branch: branch, name: "Back gate", active: false)
    create(:biometric_device, business: business, branch: other, name: "Elsewhere")

    notices = described_class.notices_for(branch: branch)

    expect(notices.size).to eq(1)
    notice = notices.first
    expect(notice).to be_a(OrganizationAccess::BranchDeactivationNotices::Notice)
    expect(notice.title).to eq(I18n.t("attendance.deactivation_notice.title"))
    expect(notice.summary).to include("Back gate (device inactive), Front door")
    expect(notice.summary).not_to include("Elsewhere")
    expect(notice.lines.map(&:to_h)).to eq([ { label: I18n.t("attendance.deactivation_notice.devices_assigned"), value: 2 } ])
  end

  it "explains that punches will not be applied after deactivation" do
    create(:biometric_device, business: business, branch: branch)

    expect(described_class.notices_for(branch: branch).first.summary).to include("not applied to attendance")
  end

  it "is translated" do
    create(:biometric_device, business: business, branch: branch, name: "Door", active: false)

    summary = I18n.with_locale(:ar) { described_class.notices_for(branch: branch).first.summary }

    expect(summary).to include("Door (الجهاز غير نشط)")
  end

  it "changes no device" do
    device = create(:biometric_device, business: business, branch: branch)

    expect { described_class.notices_for(branch: branch) }.not_to change { device.reload.attributes }
  end

  it "passes the contract's shape check" do
    create(:biometric_device, business: business, branch: branch)

    expect(OrganizationAccess::BranchDeactivationNotices.notices_for(branch: branch).map(&:title))
      .to include(I18n.t("attendance.deactivation_notice.title"))
  end
end
