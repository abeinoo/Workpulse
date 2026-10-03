require "rails_helper"

RSpec.describe OrganizationAccess::PermissionCatalog, type: :model do
  describe ".group" do
    it "returns PermissionRole's own group definition for every group (delegation, no copy)" do
      PermissionRole::PERMISSION_GROUPS.each do |name, permissions|
        expect(described_class.group(name)).to equal(permissions)
      end
    end

    it "accepts the group name as a String or a Symbol" do
      expect(described_class.group("laundry_operations")).to equal(PermissionRole::PERMISSION_GROUPS[:laundry_operations])
    end

    it "returns the groups other domains consume today" do
      expect(described_class.group(:laundry_operations) + described_class.group(:laundry_cost_reports))
        .to eq(Laundry::BaseController::LAUNDRY_PERMISSIONS.map(&:to_s))
      expect(described_class.group(:employee_onboarding)).to eq(PermissionRole::PERMISSION_GROUPS[:employee_onboarding])
    end

    it "raises KeyError for an unknown group" do
      expect { described_class.group(:not_a_group) }.to raise_error(KeyError)
    end
  end
end
