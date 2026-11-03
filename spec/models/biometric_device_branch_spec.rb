require "rails_helper"

# A biometric device is registered to the branch it is installed at; its punch
# logs copy that branch once. Both stay inside the device's business.
RSpec.describe BiometricDevice, "branch" do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }

  it "is optional (devices registered before branches existed keep working)" do
    expect(build(:biometric_device, business: business, branch: nil)).to be_valid
  end

  it "accepts an active branch of the device's business" do
    expect(build(:biometric_device, business: business, branch: branch)).to be_valid
  end

  it "rejects a branch of another business" do
    device = build(:biometric_device, business: business, branch: create(:branch))

    expect(device).not_to be_valid
    expect(device.errors.details[:branch]).to include(error: :other_business)
  end

  it "rejects assigning an inactive branch" do
    device = build(:biometric_device, business: business, branch: create(:branch, :inactive, business: business))

    expect(device).not_to be_valid
    expect(device.errors.details[:branch]).to include(error: :branch_inactive)
  end

  it "still lets a device whose branch was deactivated later be edited or deactivated" do
    device = create(:biometric_device, business: business, branch: branch)
    branch.update_column(:active, false)

    expect(device.reload.update(name: "Renamed", active: false)).to be(true)
  end

  it "lists devices with no branch" do
    unassigned = create(:biometric_device, business: business, branch: nil)
    create(:biometric_device, business: business, branch: branch)

    expect(described_class.without_branch).to contain_exactly(unassigned)
  end

  describe BiometricPunchLog do
    it "rejects a branch of another business" do
      log = build(:biometric_punch_log, business: business, branch: create(:branch))

      expect(log).not_to be_valid
      expect(log.errors.details[:branch]).to include(error: :other_business)
    end

    it "treats a refused inactive-branch punch as neither spam nor aggregation evidence" do
      expect(BiometricPunchLog::NOT_SPAM_ACTIONS).to include("rejected_branch_inactive")
      expect(Attendance::PunchAggregator::EVIDENCE_ACTIONS).not_to include("rejected_branch_inactive")
    end
  end
end
