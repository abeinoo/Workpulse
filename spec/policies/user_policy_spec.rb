require "rails_helper"

RSpec.describe UserPolicy, type: :model do
  let(:business)    { create(:business) }
  let(:branch)      { create(:branch, business: business) }
  let(:super_admin) { create(:user, :super_admin, business: business) }
  let(:manager)     { create(:user, :branch_manager, business: business) }
  let(:employee)    { create(:user, business: business, manager: manager) }
  let(:other_user)  { create(:user, business: business) }

  before do
    create(:user_branch, user: manager, branch: branch)
    create(:user_branch, user: employee, branch: branch)
  end

  subject { described_class }

  describe "index?" do
    it "permits super_admin" do
      expect(subject).to permit(super_admin, other_user)
    end

    it "permits branch_manager" do
      expect(subject).to permit(manager, other_user)
    end

    it "denies employee" do
      expect(subject).not_to permit(employee, other_user)
    end
  end

  describe "show?" do
    it "permits super_admin to view any user" do
      expect(subject).to permit(super_admin, employee)
    end

    it "permits employee to view their own record" do
      expect(subject).to permit(employee, employee)
    end

    it "permits branch_manager to view an employee in their branch" do
      expect(subject).to permit(manager, employee)
    end

    it "denies branch_manager to view a user in a different branch" do
      other_branch = create(:branch, business: business)
      other_employee = create(:user, business: business)
      create(:user_branch, user: other_employee, branch: other_branch)
      expect(subject).not_to permit(manager, other_employee)
    end

    it "denies employee viewing another employee" do
      expect(subject).not_to permit(employee, other_user)
    end
  end

  describe "create?" do
    it "permits super_admin" do
      expect(subject).to permit(super_admin, User.new)
    end

    it "denies branch_manager" do
      expect(subject).not_to permit(manager, User.new)
    end

    it "denies employee" do
      expect(subject).not_to permit(employee, User.new)
    end
  end

  describe "update?" do
    it "permits super_admin to update any user" do
      expect(subject).to permit(super_admin, employee)
    end

    it "permits employee to update their own record" do
      expect(subject).to permit(employee, employee)
    end

    it "denies employee updating another user" do
      expect(subject).not_to permit(employee, other_user)
    end

    it "denies branch_manager updating another user" do
      expect(subject).not_to permit(manager, employee)
    end
  end

  describe "destroy?" do
    it "permits super_admin" do
      expect(subject).to permit(super_admin, employee)
    end

    it "denies branch_manager" do
      expect(subject).not_to permit(manager, employee)
    end

    it "denies employee" do
      expect(subject).not_to permit(employee, other_user)
    end
  end

  describe "Scope" do
    let!(:riyadh_employee) { employee }
    let!(:other_business_user) { create(:user) }

    describe "super_admin scope" do
      it "returns all users in the same business" do
        scope = described_class::Scope.new(super_admin, User).resolve
        expect(scope).to include(riyadh_employee, manager)
        expect(scope).not_to include(other_business_user)
      end
    end

    describe "branch_manager scope" do
      it "includes directly managed employees" do
        scope = described_class::Scope.new(manager, User).resolve
        expect(scope).to include(riyadh_employee)
        expect(scope).not_to include(other_business_user)
      end

      it "excludes employees managed by a different manager" do
        other_manager  = create(:user, :branch_manager, business: business)
        other_employee = create(:user, business: business, manager: other_manager)
        scope = described_class::Scope.new(manager, User).resolve
        expect(scope).not_to include(other_employee)
      end

      it "includes the manager themselves" do
        scope = described_class::Scope.new(manager, User).resolve
        expect(scope).to include(manager)
      end
    end

    describe "employee scope" do
      it "returns only themselves" do
        scope = described_class::Scope.new(employee, User).resolve
        expect(scope).to contain_exactly(employee)
      end
    end
  end
end
