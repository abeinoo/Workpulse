require "rails_helper"

RSpec.describe PermissionRolePolicy, type: :model do
  let(:business)          { create(:business) }
  let(:owner)             { create(:user, :super_admin, business: business) }
  let(:plain_emp)         { create(:user, business: business) }
  let(:manage_roles_role) { create(:permission_role, :with_manage_roles, business: business) }
  let(:manager_user)      { create(:user, business: business, permission_role: manage_roles_role) }
  let(:role)              { create(:permission_role, business: business) }

  subject { described_class }

  describe "index?" do
    it "permits owner (super_admin)" do
      expect(subject).to permit(owner, role)
    end

    it "permits user with manage_roles permission" do
      expect(subject).to permit(manager_user, role)
    end

    it "denies plain employee without permission_role" do
      expect(subject).not_to permit(plain_emp, role)
    end
  end

  describe "show?" do
    it "permits owner (super_admin)" do
      expect(subject).to permit(owner, role)
    end

    it "permits user with manage_roles permission" do
      expect(subject).to permit(manager_user, role)
    end

    it "denies plain employee without permission_role" do
      expect(subject).not_to permit(plain_emp, role)
    end
  end

  describe "create?" do
    it "permits owner (super_admin)" do
      expect(subject).to permit(owner, PermissionRole.new(business: business))
    end

    it "permits user with manage_roles permission" do
      expect(subject).to permit(manager_user, PermissionRole.new(business: business))
    end

    it "denies plain employee without permission_role" do
      expect(subject).not_to permit(plain_emp, PermissionRole.new(business: business))
    end
  end

  describe "update?" do
    it "permits owner (super_admin)" do
      expect(subject).to permit(owner, role)
    end

    it "permits user with manage_roles permission" do
      expect(subject).to permit(manager_user, role)
    end

    it "denies plain employee without permission_role" do
      expect(subject).not_to permit(plain_emp, role)
    end
  end

  describe "destroy?" do
    it "permits owner (super_admin)" do
      expect(subject).to permit(owner, role)
    end

    it "permits user with manage_roles permission" do
      expect(subject).to permit(manager_user, role)
    end

    it "denies plain employee without permission_role" do
      expect(subject).not_to permit(plain_emp, role)
    end
  end

  describe "Scope" do
    let(:other_business) { create(:business) }
    let!(:own_role)      { create(:permission_role, business: business) }
    let!(:other_role)    { create(:permission_role, business: other_business) }

    it "returns only roles belonging to the user's business" do
      scope = PermissionRolePolicy::Scope.new(owner, PermissionRole.all).resolve
      expect(scope).to include(own_role)
      expect(scope).not_to include(other_role)
    end
  end
end
