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
        role = build(:permission_role, permissions: [ "", "view_employees", "" ])
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
          role = build(:permission_role, permissions: [ perm ])
          expect(role).not_to be_valid
          deps.each do |dep|
            # Collect transitive deps one level deep so the role_with_dep set is
            # actually satisfiable (e.g. manage_adjustments also requires view_adjustments).
            transitive = PermissionRole::PERMISSION_DEPENDENCIES.fetch(dep, [])
            candidate_perms = ([ perm, dep ] + transitive).uniq
            role_with_dep = build(:permission_role, permissions: candidate_perms)
            # Only valid once ALL of perm's direct deps are present in the candidate set.
            if PermissionRole::PERMISSION_DEPENDENCIES[perm].all? { |d| candidate_perms.include?(d) }
              expect(role_with_dep).to be_valid
            end
          end
        end
      end
    end
  end

  # ── Constants ───────────────────────────────────────────────────────────────
  describe "PERMISSION_GROUPS" do
    it "covers exactly 23 groups" do
      expect(PermissionRole::PERMISSION_GROUPS.keys.size).to eq(23)
    end

    it "has 115 total permissions" do
      expect(PermissionRole::ALL_PERMISSIONS.size).to eq(115)
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
                   permission_scopes: { "view_payroll" => "branch" })
      expect(role.scope_for(:view_payroll)).to eq("branch")
    end

    it "normalizes legacy scope names to the canonical set" do
      role = build(:permission_role,
                   permissions:       %w[view_payroll],
                   permission_scopes: { "view_payroll" => "branch_only" })
      expect(role.scope_for(:view_payroll)).to eq("branch")
    end

    it "strips scope entries for permissions that are not granted (before_validation)" do
      role = build(:permission_role,
                   permissions:       %w[view_attendance],
                   permission_scopes: { "view_attendance" => "self",
                                        "view_payroll"    => "business" })
      role.valid?
      expect(role.permission_scopes.keys).to contain_exactly("view_attendance")
    end
  end

  describe ".scope_options_for and scope validation" do
    it "offers all four scope options for an ordinary scopable permission" do
      expect(PermissionRole.scope_options_for("view_payroll")).to eq(%w[self branch area business])
    end

    %w[view_towel_balances create_towel_transfers confirm_towel_receipt
       view_laundry_consumption_reports].each do |perm|
      # create_towel_transfers/confirm_towel_receipt depend on view_towel_balances
      # (PERMISSION_DEPENDENCIES) — include it so these examples isolate the
      # scope behavior under test, not an unrelated dependency failure.
      required_perms = ([ perm ] + PermissionRole::PERMISSION_DEPENDENCIES.fetch(perm, [])).uniq

      it "excludes 'self' (Personal Only) for the Laundry permission '#{perm}'" do
        expect(PermissionRole.scope_options_for(perm)).to eq(%w[branch area business])
      end

      it "rejects 'self' persisted directly for '#{perm}', bypassing the UI" do
        role = build(:permission_role, permissions: required_perms, permission_scopes: { perm => "self" })
        expect(role).not_to be_valid
        expect(role.errors[:permission_scopes]).to be_present
      end

      %w[branch area business].each do |scope|
        it "accepts '#{scope}' for '#{perm}'" do
          role = build(:permission_role, permissions: required_perms, permission_scopes: { perm => scope })
          expect(role).to be_valid
        end
      end
    end

    it "still allows 'self' for a non-Laundry scopable permission (e.g. view_payroll)" do
      role = build(:permission_role, permissions: %w[view_payroll], permission_scopes: { "view_payroll" => "self" })
      expect(role).to be_valid
    end

    it "still allows 'self' for the pre-existing DR management minimum-scope exclusion list unaffected by this change" do
      expect(PermissionRole::BRANCH_MINIMUM_SCOPE_PERMISSIONS).to include("view_daily_reconciliation")
      expect(PermissionRole.scope_options_for("view_daily_reconciliation")).not_to include("self")
    end

    it "rejects a scope value entirely outside SCOPE_OPTIONS" do
      role = build(:permission_role, permissions: %w[view_payroll], permission_scopes: { "view_payroll" => "planet" })
      expect(role).not_to be_valid
      expect(role.errors[:permission_scopes]).to be_present
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
