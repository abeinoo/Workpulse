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
        role = build(:permission_role, permissions: %w[view_employees view_employees view_payroll])
        expect(role).to be_valid
        expect(role.permissions).to eq(%w[view_employees view_payroll])
      end
    end

    describe "dependency validation" do
      it "is valid when all dependencies are satisfied" do
        role = build(:permission_role, permissions: %w[view_attendance manage_attendance])
        expect(role).to be_valid
      end

      it "is invalid when a dependency is missing" do
        role = build(:permission_role, permissions: %w[manage_attendance])
        expect(role).not_to be_valid
        expect(role.errors[:permissions].join).to match(/requires.*view_attendance/i)
      end

      it "reports all missing dependencies in one pass" do
        role = build(:permission_role, permissions: %w[manage_employees manage_salary_profiles])
        # manage_employees requires view_employees; manage_salary_profiles also requires view_employees
        expect(role).not_to be_valid
        expect(role.errors[:permissions].size).to be >= 2
      end

      it "is valid when the dependent permission is not present" do
        role = build(:permission_role, permissions: %w[view_attendance])
        expect(role).to be_valid
      end

      PermissionRole::PERMISSION_DEPENDENCIES.each do |perm, deps|
        it "#{perm} requires #{deps.join(', ')}" do
          role = build(:permission_role, permissions: [perm])
          expect(role).not_to be_valid
          deps.each do |dep|
            role_with_dep = build(:permission_role, permissions: [perm, dep])
            # Only valid once ALL deps (not just this one) are present
            if PermissionRole::PERMISSION_DEPENDENCIES[perm].all? { |d| [perm, dep].include?(d) }
              expect(role_with_dep).to be_valid
            end
          end
        end
      end
    end
  end

  # ── Constants ───────────────────────────────────────────────────────────────
  describe "PERMISSION_GROUPS" do
    it "covers exactly 10 groups" do
      expect(PermissionRole::PERMISSION_GROUPS.keys.size).to eq(10)
    end

    it "has 34 total permissions" do
      expect(PermissionRole::ALL_PERMISSIONS.size).to eq(34)
    end

    it "includes view_payroll_analytics as a separate permission from view_payroll" do
      expect(PermissionRole::ALL_PERMISSIONS).to include("view_payroll", "view_payroll_analytics")
    end

    it "splits the payroll workflow into per-action permissions" do
      expect(PermissionRole::ALL_PERMISSIONS).to include(
        "create_payroll", "regenerate_payroll", "submit_payroll_review",
        "complete_branch_review", "approve_payroll_items",
        "finalize_payroll", "pay_payroll", "reopen_payroll", "delete_payroll",
        "view_payroll_audit_log"
      )
      expect(PermissionRole::ALL_PERMISSIONS).not_to include("manage_payroll"),
        "manage_payroll has been replaced by granular permissions"
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

  describe "#scope_for" do
    it "returns nil when no scope is configured for the permission" do
      role = build(:permission_role, permissions: %w[view_payroll])
      expect(role.scope_for(:view_payroll)).to be_nil
    end

    it "returns the configured scope string" do
      role = build(:permission_role,
                   permissions:       %w[view_payroll],
                   permission_scopes: { "view_payroll" => "managed_employees_only" })
      expect(role.scope_for(:view_payroll)).to eq("managed_employees_only")
    end

    it "strips scope entries for permissions that are not granted (before_validation)" do
      role = build(:permission_role,
                   permissions:       %w[view_attendance],
                   permission_scopes: { "view_attendance" => "self_only",
                                        "view_payroll"    => "business_wide" })
      role.valid?
      expect(role.permission_scopes.keys).to contain_exactly("view_attendance")
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
