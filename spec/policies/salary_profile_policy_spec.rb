require "rails_helper"

RSpec.describe SalaryProfilePolicy, type: :model do
  let(:business)    { create(:business) }
  let(:branch)      { create(:branch, business: business) }
  let(:other_biz)   { create(:business) }

  let(:super_admin) { create(:user, :super_admin,    business: business) }
  let(:accountant)  { create(:user, :accountant,     business: business) }
  let(:manager)     { create(:user, :branch_manager, business: business) }
  let(:employee)    { create(:user,                  business: business) }

  before do
    branch.update_column(:branch_manager_id, manager.id)
    create(:user_branch, user: manager,  branch: branch)
    create(:user_branch, user: employee, branch: branch)
  end

  let(:active_profile)     { create(:salary_profile, user: employee) }
  let(:historical_profile) do
    p = create(:salary_profile, user: employee)
    # Create a second (newer) profile so the first becomes historical
    create(:salary_profile, user: employee, effective_from: Date.current)
    p.reload
  end

  subject { described_class }

  describe "show?" do
    it "permits super_admin" do
      expect(subject.new(super_admin, active_profile).show?).to be true
    end

    it "permits accountant" do
      expect(subject.new(accountant, active_profile).show?).to be true
    end

    it "permits the branch manager of the employee" do
      expect(subject.new(manager, active_profile).show?).to be true
    end

    it "permits the employee to view their own profile" do
      expect(subject.new(employee, active_profile).show?).to be true
    end
  end

  describe "create?" do
    it "permits super_admin" do
      expect(subject.new(super_admin, SalaryProfile.new(user: employee)).create?).to be true
    end

    it "denies accountant" do
      expect(subject.new(accountant, SalaryProfile.new(user: employee)).create?).to be false
    end

    it "denies branch_manager" do
      expect(subject.new(manager, SalaryProfile.new(user: employee)).create?).to be false
    end

    it "denies employee" do
      expect(subject.new(employee, SalaryProfile.new(user: employee)).create?).to be false
    end
  end

  describe "update?" do
    it "permits super_admin on an active profile" do
      expect(subject.new(super_admin, active_profile).update?).to be true
    end

    it "denies super_admin on a historical profile" do
      expect(subject.new(super_admin, historical_profile).update?).to be false
    end

    it "denies accountant even on an active profile" do
      expect(subject.new(accountant, active_profile).update?).to be false
    end

    it "denies branch_manager" do
      expect(subject.new(manager, active_profile).update?).to be false
    end

    it "denies employee" do
      expect(subject.new(employee, active_profile).update?).to be false
    end
  end

  describe "destroy?" do
    it "denies everyone" do
      [ super_admin, accountant, manager, employee ].each do |u|
        expect(subject.new(u, active_profile).destroy?).to be false
      end
    end
  end

  describe "Scope" do
    before { active_profile }

    let(:other_employee) { create(:user, business: other_biz) }
    let!(:other_profile) { create(:salary_profile, user: other_employee) }

    it "returns profiles for the same business when super_admin" do
      scope = SalaryProfilePolicy::Scope.new(super_admin, SalaryProfile).resolve
      expect(scope).to include(active_profile)
      expect(scope).not_to include(other_profile)
    end

    it "returns profiles for the same business when accountant" do
      scope = SalaryProfilePolicy::Scope.new(accountant, SalaryProfile).resolve
      expect(scope).to include(active_profile)
      expect(scope).not_to include(other_profile)
    end

    it "returns only managed employees' profiles for branch_manager" do
      scope = SalaryProfilePolicy::Scope.new(manager, SalaryProfile).resolve
      expect(scope).to include(active_profile)
      expect(scope).not_to include(other_profile)
    end

    it "excludes profiles for employees in a different branch of the same business" do
      other_branch   = create(:branch, business: business)
      other_mgr      = create(:user, :branch_manager, business: business)
      cross_emp      = create(:user, business: business)
      cross_profile  = create(:salary_profile, user: cross_emp)
      create(:user_branch, user: cross_emp, branch: other_branch)
      # manager is only in `branch`, not other_branch — must not see cross_emp's profile
      scope = SalaryProfilePolicy::Scope.new(manager, SalaryProfile).resolve
      expect(scope).not_to include(cross_profile)
    end

    it "returns only own profile for employee" do
      scope = SalaryProfilePolicy::Scope.new(employee, SalaryProfile).resolve
      expect(scope).to include(active_profile)
    end
  end
end
