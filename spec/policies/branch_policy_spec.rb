require "rails_helper"

RSpec.describe BranchPolicy, type: :model do
  let(:business)   { create(:business) }
  let(:branch)     { create(:branch, business: business) }
  let(:owner)      { create(:user, :owner,          business: business) }
  let(:accountant) { create(:user, :accountant,     business: business) }
  let(:manager)    { create(:user, :branch_manager, business: business) }
  let(:employee)   { create(:user,                  business: business) }

  before do
    branch.update_column(:branch_manager_id, manager.id)
  end

  subject { described_class }

  describe "index?" do
    it "permits owner"         do expect(subject.new(owner,    branch).index?).to be true  end
    it "denies branch_manager without manage_branches permission" do expect(subject.new(manager, branch).index?).to be false end
    it "denies accountant"     do expect(subject.new(accountant, branch).index?).to be false end
    it "denies employee"       do expect(subject.new(employee, branch).index?).to be false end
  end

  describe "show?" do
    it "permits owner"             do expect(subject.new(owner,    branch).show?).to be true  end
    it "denies manager without manage_branches permission" do expect(subject.new(manager, branch).show?).to be false end
    it "denies employee"           do expect(subject.new(employee, branch).show?).to be false end
  end

  describe "create? / destroy?" do
    it "permits owner to create"  do expect(subject.new(owner,    branch).create?).to be true  end
    it "denies manager to create" do expect(subject.new(manager,  branch).create?).to be false end
    it "permits owner to destroy" do expect(subject.new(owner,    branch).destroy?).to be true  end
    it "denies manager to destroy" do expect(subject.new(manager, branch).destroy?).to be false end
  end

  describe "cross-business isolation (Scope)" do
    let(:other_business) { create(:business) }
    let(:other_branch)   { create(:branch, business: other_business) }

    it "never returns branches from another business" do
      scope = subject::Scope.new(owner, Branch.all).resolve
      expect(scope).to     include(branch)
      expect(scope).not_to include(other_branch)
    end
  end
end
