require "rails_helper"

RSpec.describe EmployeeInsuranceProfilePolicy, type: :model do
  let(:business)  { create(:business) }
  let(:branch_a)  { create(:branch, business: business) }
  let(:branch_b)  { create(:branch, business: business) }
  let(:other_biz) { create(:business) }

  let(:owner) { create(:user, :owner, business: business) }

  let(:branch_role) do
    create(:permission_role, business: business,
           permissions: %w[view_employee_insurance],
           permission_scopes: { "view_employee_insurance" => "branch" })
  end
  let(:area_role) do
    create(:permission_role, business: business,
           permissions: %w[view_employee_insurance],
           permission_scopes: { "view_employee_insurance" => "area" })
  end
  let(:business_role) do
    create(:permission_role, business: business,
           permissions: %w[view_employee_insurance],
           permission_scopes: { "view_employee_insurance" => "business" })
  end
  let(:unscoped_manage_role) do
    create(:permission_role, business: business, permissions: %w[view_employee_insurance manage_employee_insurance])
  end

  let(:branch_manager_user) { create(:user, business: business, permission_role: branch_role) }
  let(:area_manager_user)   { create(:user, business: business, permission_role: area_role) }
  let(:business_user)       { create(:user, business: business, permission_role: business_role) }

  before do
    branch_a.update_column(:branch_manager_id, branch_manager_user.id)
    branch_a.update_column(:area_manager_id, area_manager_user.id)
    branch_b.update_column(:area_manager_id, area_manager_user.id)
  end

  let!(:employee_in_branch_a) { create(:user, business: business) }
  let!(:employee_in_branch_b) { create(:user, business: business) }

  before do
    create(:shift_assignment, business: business, user: employee_in_branch_a, branch: branch_a)
    create(:shift_assignment, business: business, user: employee_in_branch_b, branch: branch_b)
  end

  let!(:profile_a) { create(:employee_insurance_profile, user: employee_in_branch_a) }
  let!(:profile_b) { create(:employee_insurance_profile, user: employee_in_branch_b) }

  let(:other_employee) { create(:user, business: other_biz) }
  let!(:other_profile) { create(:employee_insurance_profile, user: other_employee) }

  subject { described_class }

  describe "show?" do
    it "permits the employee to view their own profile" do
      expect(subject.new(employee_in_branch_a, profile_a).show?).to be true
    end

    it "denies an employee viewing someone else's profile" do
      expect(subject.new(employee_in_branch_a, profile_b).show?).to be false
    end

    it "permits a business-scoped role" do
      expect(subject.new(business_user, profile_b).show?).to be true
    end
  end

  describe "create?/update?" do
    # No scope configured → the manager hierarchy, as in Scope (SEC-P8-2).
    it "permits a role with manage_employee_insurance for an employee in its scope, not outside it" do
      manager = create(:user, business: business, permission_role: unscoped_manage_role)
      branch_a.update_column(:branch_manager_id, manager.id)
      expect(subject.new(manager, profile_a).update?).to be true
      expect(subject.new(manager, profile_b).update?).to be false
    end

    it "denies a view-only role" do
      expect(subject.new(branch_manager_user, profile_a).update?).to be false
    end

    it "denies destroy for everyone" do
      manager = create(:user, business: business, permission_role: unscoped_manage_role)
      expect(subject.new(manager, profile_a).destroy?).to be false
    end
  end

  describe "view_employer_contribution?" do
    it "is false for a plain view-scoped role" do
      expect(subject.new(branch_manager_user, profile_a).view_employer_contribution?).to be false
    end

    it "is true for a role with manage_employee_insurance" do
      manager = create(:user, business: business, permission_role: unscoped_manage_role)
      expect(subject.new(manager, profile_a).view_employer_contribution?).to be true
    end
  end

  describe "Scope" do
    it "restricts a branch-scoped role to employees in their managed branch" do
      scope = described_class::Scope.new(branch_manager_user, EmployeeInsuranceProfile).resolve
      expect(scope).to include(profile_a)
      expect(scope).not_to include(profile_b)
      expect(scope).not_to include(other_profile)
    end

    it "restricts an area-scoped role to employees across their managed area's branches" do
      scope = described_class::Scope.new(area_manager_user, EmployeeInsuranceProfile).resolve
      expect(scope).to include(profile_a)
      expect(scope).to include(profile_b)
      expect(scope).not_to include(other_profile)
    end

    it "grants full business visibility for a business-scoped role" do
      scope = described_class::Scope.new(business_user, EmployeeInsuranceProfile).resolve
      expect(scope).to include(profile_a, profile_b)
      expect(scope).not_to include(other_profile)
    end

    it "grants owners full business visibility regardless of configured scope" do
      scope = described_class::Scope.new(owner, EmployeeInsuranceProfile).resolve
      expect(scope).to include(profile_a, profile_b)
      expect(scope).not_to include(other_profile)
    end

    it "falls back to the manager hierarchy when no explicit scope is configured" do
      manager = create(:user, business: business, permission_role: unscoped_manage_role)
      branch_a.update_column(:branch_manager_id, manager.id)

      scope = described_class::Scope.new(manager, EmployeeInsuranceProfile).resolve
      expect(scope).to include(profile_a)
      expect(scope).not_to include(profile_b)
    end

    it "restricts a user without the permission to their own profile only" do
      scope = described_class::Scope.new(employee_in_branch_a, EmployeeInsuranceProfile).resolve
      expect(scope).to include(profile_a)
      expect(scope).not_to include(profile_b)
      expect(scope).not_to include(other_profile)
    end

    it "never leaks profiles from another business" do
      scope = described_class::Scope.new(business_user, EmployeeInsuranceProfile).resolve
      expect(scope).not_to include(other_profile)
    end
  end
end
