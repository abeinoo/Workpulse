require "rails_helper"

RSpec.describe OrganizationAccess::Authorization, type: :model do
  let(:business) { create(:business) }

  describe ".granted_permissions" do
    it "returns the role's stored permissions for a role holder" do
      role = create(:permission_role, business: business, permissions: %w[view_attendance view_shifts])
      user = create(:user, business: business, permission_role: role)

      expect(described_class.granted_permissions(user)).to eq(%w[view_attendance view_shifts])
      expect(described_class.granted_permissions(user)).to eq(user.permission_role.permissions)
    end

    it "is empty for a user without a role" do
      expect(described_class.granted_permissions(create(:user, business: business))).to eq([])
    end

    it "is empty for the owner, who holds every permission through User#can? but has no role" do
      owner = create(:user, :owner, business: business)

      expect(described_class.granted_permissions(owner)).to eq([])
      expect(owner.can?(:manage_roles)).to be(true)
    end

    it "follows role edits (reads the role, keeps no copy)" do
      role = create(:permission_role, business: business, permissions: %w[view_attendance])
      user = create(:user, business: business, permission_role: role)
      role.update!(permissions: %w[view_attendance view_payroll])

      expect(described_class.granted_permissions(user.reload)).to eq(%w[view_attendance view_payroll])
    end
  end
end
