require "rails_helper"

RSpec.describe PermissionRole, type: :model do
  subject(:role) { build(:permission_role) }

  # ── Associations ────────────────────────────────────────────────────────────
  describe "associations" do
    it { is_expected.to belong_to(:business) }
    it { is_expected.to have_many(:users).dependent(:nullify) }
  end

  # ── Validations ─────────────────────────────────────────────────────────────
  describe "validations" do
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_length_of(:name).is_at_most(80) }

    describe "name uniqueness per business" do
      let(:business) { create(:business) }

      it "rejects duplicate names within the same business" do
        create(:permission_role, business: business, name: "Supervisor")
        duplicate = build(:permission_role, business: business, name: "Supervisor")
        expect(duplicate).not_to be_valid
        expect(duplicate.errors[:name]).to be_present
      end

      it "allows the same name across different businesses" do
        other_business = create(:business)
        create(:permission_role, business: business,       name: "Supervisor")
        other           = build(:permission_role, business: other_business, name: "Supervisor")
        expect(other).to be_valid
      end

      it "is case-insensitive" do
        create(:permission_role, business: business, name: "Supervisor")
        duplicate = build(:permission_role, business: business, name: "SUPERVISOR")
        expect(duplicate).not_to be_valid
      end
    end

    describe "permissions validation" do
      it "accepts an empty array" do
        expect(build(:permission_role, permissions: [])).to be_valid
      end

      it "accepts all known permissions" do
        expect(build(:permission_role, permissions: PermissionRole::ALL_PERMISSIONS)).to be_valid
      end

      it "rejects unknown permission strings" do
        role = build(:permission_role, permissions: %w[view_employees do_something_bad])
        expect(role).not_to be_valid
        expect(role.errors[:permissions]).to be_present
      end

      it "strips blank strings from the hidden-field sentinel before validating" do
        # Rails form helpers emit permissions[]='' as a sentinel; ensure it is silently dropped
        role = build(:permission_role, permissions: ["", "view_employees", ""])
        expect(role).to be_valid
        expect(role.permissions).to eq(%w[view_employees])
      end

      it "deduplicates repeated permission values" do
        role = build(:permission_role, permissions: %w[view_employees view_employees manage_payroll])
        expect(role).to be_valid
        expect(role.permissions).to eq(%w[view_employees manage_payroll])
      end
    end
  end

  # ── Constants ───────────────────────────────────────────────────────────────
  describe "PERMISSION_GROUPS" do
    it "covers exactly 9 groups" do
      expect(PermissionRole::PERMISSION_GROUPS.keys.size).to eq(9)
    end

    it "has 22 total permissions" do
      expect(PermissionRole::ALL_PERMISSIONS.size).to eq(22)
    end

    it "contains no duplicates" do
      expect(PermissionRole::ALL_PERMISSIONS.uniq.size).to eq(PermissionRole::ALL_PERMISSIONS.size)
    end
  end

  # ── Instance methods ────────────────────────────────────────────────────────
  describe "#has_permission?" do
    subject(:role) { build(:permission_role, permissions: %w[view_employees manage_payroll]) }

    it "returns true for a granted permission (string)" do
      expect(role.has_permission?("view_employees")).to be true
    end

    it "returns true for a granted permission (symbol)" do
      expect(role.has_permission?(:view_employees)).to be true
    end

    it "returns false for a permission not in the list" do
      expect(role.has_permission?(:finalize_payroll)).to be false
    end
  end

  describe "#permission_count" do
    it "returns the number of permissions granted" do
      role = build(:permission_role, permissions: %w[view_employees view_payroll])
      expect(role.permission_count).to eq(2)
    end
  end

  describe "#user_count" do
    it "returns the number of users assigned" do
      business = create(:business)
      role     = create(:permission_role, business: business)
      create(:user, business: business, permission_role: role)
      create(:user, business: business, permission_role: role)
      expect(role.user_count).to eq(2)
    end
  end
end
