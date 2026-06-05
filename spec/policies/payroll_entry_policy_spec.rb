require "rails_helper"

RSpec.describe PayrollEntryPolicy, type: :model do
  let(:business)    { create(:business) }
  let(:branch)      { create(:branch, business: business) }
  let(:super_admin) { create(:user, :super_admin, business: business) }
  let(:accountant)  { create(:user, :accountant,  business: business) }
  let(:manager)     { create(:user, :branch_manager, business: business) }
  let(:area_mgr)    { create(:user, :area_manager, business: business) }
  let(:employee)    { create(:user, business: business) }

  before do
    branch.update_column(:branch_manager_id, manager.id)
    create(:user_branch, user: manager,  branch: branch)
    create(:user_branch, user: employee, branch: branch)
  end

  let(:period) { create(:payroll_period, :finalized, business: business) }
  let(:entry)  { create(:payroll_entry,  payroll_period: period, user: employee) }

  subject { described_class }

  describe "index?" do
    it "permits super_admin"    do expect(subject).to permit(super_admin, entry) end
    it "permits accountant"     do expect(subject).to permit(accountant,  entry) end
    it "permits area_manager"   do expect(subject).to permit(area_mgr,    entry) end
    it "permits branch_manager" do expect(subject).to permit(manager,     entry) end
    it "permits employee (scope handles isolation)" do
      expect(subject).to permit(employee, entry)
    end
  end

  describe "show?" do
    it "permits super_admin"    do expect(subject.new(super_admin, entry).show?).to be true  end
    it "permits accountant"     do expect(subject.new(accountant,  entry).show?).to be true  end
    it "permits area_manager"   do expect(subject.new(area_mgr,    entry).show?).to be true  end
    it "permits branch_manager" do expect(subject.new(manager,     entry).show?).to be true  end

    it "permits employee to see their own entry" do
      expect(subject.new(employee, entry).show?).to be true
    end

    it "denies a different employee" do
      other = create(:user, business: business)
      expect(subject.new(other, entry).show?).to be false
    end
  end

  describe "update?" do
    it "permits super_admin"    do expect(subject.new(super_admin, entry).update?).to be true  end
    it "permits accountant"     do expect(subject.new(accountant,  entry).update?).to be true  end
    it "denies branch_manager"  do expect(subject.new(manager,     entry).update?).to be false end
    it "denies employee"        do expect(subject.new(employee,    entry).update?).to be false end
  end

  describe "override_overtime?" do
    let(:draft_period) { create(:payroll_period, business: business, status: :draft) }
    let(:draft_entry)  { create(:payroll_entry, payroll_period: draft_period, user: employee) }

    it "permits accountant on a reviewable period" do
      expect(subject.new(accountant, draft_entry).override_overtime?).to be true
    end

    it "denies branch_manager (no manage_payroll_overrides)" do
      expect(subject.new(manager, draft_entry).override_overtime?).to be false
    end

    it "denies employee" do
      expect(subject.new(employee, draft_entry).override_overtime?).to be false
    end

    it "denies even an accountant once the period is locked" do
      expect(subject.new(accountant, entry).override_overtime?).to be false # entry uses a :finalized period
    end
  end

  describe "Scope" do
    let!(:my_entry)    { entry }
    let!(:other_entry) { create(:payroll_entry) }

    describe "super_admin scope" do
      it "includes all entries for the business" do
        scope = described_class::Scope.new(super_admin, PayrollEntry).resolve
        expect(scope).to     include(my_entry)
        expect(scope).not_to include(other_entry)
      end
    end

    describe "accountant scope" do
      it "includes all entries for the business" do
        scope = described_class::Scope.new(accountant, PayrollEntry).resolve
        expect(scope).to     include(my_entry)
        expect(scope).not_to include(other_entry)
      end
    end

    describe "area_manager scope" do
      let(:area_branch) { create(:branch, business: business, area_manager: area_mgr) }

      it "includes entries for employees in managed branches" do
        managed_emp = create(:user, business: business)
        create(:user_branch, user: managed_emp, branch: area_branch)
        managed_entry = create(:payroll_entry, payroll_period: period, user: managed_emp)

        scope = described_class::Scope.new(area_mgr, PayrollEntry).resolve
        expect(scope).to     include(managed_entry)
        expect(scope).not_to include(other_entry)
      end

      it "excludes entries for employees outside their area" do
        scope = described_class::Scope.new(area_mgr, PayrollEntry).resolve
        # my_entry's employee is in `branch`, not in area_mgr's branches
        expect(scope).not_to include(my_entry)
      end
    end

    describe "branch_manager scope" do
      it "includes entries for employees in their branch" do
        scope = described_class::Scope.new(manager, PayrollEntry).resolve
        expect(scope).to     include(my_entry)
        expect(scope).not_to include(other_entry)
      end

      it "excludes entries for employees not assigned to their branch" do
        branchless_emp   = create(:user, business: business)
        branchless_entry = create(:payroll_entry, payroll_period: period, user: branchless_emp)
        scope = described_class::Scope.new(manager, PayrollEntry).resolve
        expect(scope).not_to include(branchless_entry)
      end

      it "excludes entries for employees in a different branch" do
        other_branch = create(:branch, business: business)
        other_emp    = create(:user, business: business)
        create(:user_branch, user: other_emp, branch: other_branch)
        other_entry2 = create(:payroll_entry, payroll_period: period, user: other_emp)

        scope = described_class::Scope.new(manager, PayrollEntry).resolve
        expect(scope).not_to include(other_entry2)
      end
    end

    describe "employee scope" do
      it "returns only their own entries in finalized/paid periods" do
        scope = described_class::Scope.new(employee, PayrollEntry).resolve
        expect(scope).to     include(my_entry)
        expect(scope).not_to include(other_entry)
      end

      it "excludes their own entry when period is still draft" do
        draft_period = create(:payroll_period, business: business,
                              period_year: 2025, period_month: 6)
        draft_entry = create(:payroll_entry, payroll_period: draft_period, user: employee)
        scope = described_class::Scope.new(employee, PayrollEntry).resolve
        expect(scope).not_to include(draft_entry)
      end
    end
  end
end
