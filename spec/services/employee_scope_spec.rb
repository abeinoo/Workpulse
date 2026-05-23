require "rails_helper"

RSpec.describe EmployeeScope, type: :service do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }

  let(:branch)       { create(:branch, business: business) }
  let(:other_branch) { create(:branch, business: business) }

  let(:area_manager)    { create(:user, business: business) }
  let(:branch_manager)  { create(:user, business: business) }
  let(:direct_manager)  { create(:user, business: business) }

  let(:branch_emp)      { create(:user, business: business) }
  let(:area_emp)        { create(:user, business: business) }
  let!(:direct_report)  { create(:user, business: business, manager: direct_manager) }
  let(:unrelated_emp)   { create(:user, business: business) }

  before do
    branch.update_columns(area_manager_id: area_manager.id, branch_manager_id: branch_manager.id)
    create(:user_branch, user: area_manager,   branch: branch)
    create(:user_branch, user: branch_manager, branch: branch)
    create(:user_branch, user: branch_emp,     branch: branch)
    create(:user_branch, user: area_emp,       branch: branch)
  end

  describe "#relation" do
    context "owner" do
      it "returns every non-owner user in the business" do
        result = described_class.new(owner).relation
        expect(result).to include(area_manager, branch_manager, branch_emp, unrelated_emp)
        expect(result).not_to include(owner)
      end
    end

    context "area manager" do
      it "returns employees in area-managed branches" do
        result = described_class.new(area_manager).relation
        expect(result).to include(branch_emp, area_emp, branch_manager)
      end

      it "also includes direct reports outside the branch" do
        direct_of_area = create(:user, business: business, manager: area_manager)
        result = described_class.new(area_manager).relation
        expect(result).to include(direct_of_area)
      end

      it "excludes employees in unmanaged branches" do
        other_emp = create(:user, business: business)
        create(:user_branch, user: other_emp, branch: other_branch)
        result = described_class.new(area_manager).relation
        expect(result).not_to include(other_emp)
      end
    end

    context "branch manager" do
      it "returns employees in managed branches" do
        result = described_class.new(branch_manager).relation
        expect(result).to include(branch_emp, area_emp)
      end

      it "also includes direct reports" do
        dr = create(:user, business: business, manager: branch_manager)
        result = described_class.new(branch_manager).relation
        expect(result).to include(dr)
      end

      it "excludes employees in other branches" do
        other_emp = create(:user, business: business)
        create(:user_branch, user: other_emp, branch: other_branch)
        result = described_class.new(branch_manager).relation
        expect(result).not_to include(other_emp)
      end
    end

    context "direct manager only" do
      it "returns only direct reports" do
        result = described_class.new(direct_manager).relation
        expect(result).to include(direct_report)
        expect(result).not_to include(branch_emp, unrelated_emp)
      end
    end

    context "plain employee" do
      it "returns User.none" do
        result = described_class.new(unrelated_emp).relation
        expect(result).to be_empty
      end
    end

    it "never includes the manager themselves" do
      result = described_class.new(branch_manager).relation
      expect(result).not_to include(branch_manager)
    end

    it "returns an AR relation (chainable)" do
      result = described_class.new(branch_manager).relation
      expect(result).to respond_to(:where)
      expect(result.active).to be_a(ActiveRecord::Relation)
    end
  end

  describe "#for_scope" do
    it "self_only returns only the user themselves" do
      result = described_class.new(branch_manager).for_scope("self_only")
      expect(result).to contain_exactly(branch_manager)
    end

    it "managed_employees_only delegates to #relation" do
      scope = described_class.new(branch_manager)
      expect(scope.for_scope("managed_employees_only")).to eq(scope.relation)
    end

    it "branch_only returns employees in managed branches without direct reports outside branch" do
      outside_report = create(:user, business: business, manager: branch_manager)
      result = described_class.new(branch_manager).for_scope("branch_only")
      expect(result).to include(branch_emp)
      expect(result).not_to include(outside_report)
    end

    it "business_wide returns all non-self users in the business" do
      result = described_class.new(branch_manager).for_scope("business_wide")
      expect(result).to include(branch_emp, unrelated_emp, area_manager)
      expect(result).not_to include(branch_manager)
    end

    it "unknown scope falls back to relation" do
      scope = described_class.new(branch_manager)
      expect(scope.for_scope("nonsense")).to eq(scope.relation)
    end
  end

  describe "#includes?" do
    it "returns true when the user is in the managed set" do
      expect(described_class.new(branch_manager).includes?(branch_emp.id)).to be true
    end

    it "returns false when the user is outside the managed set" do
      expect(described_class.new(branch_manager).includes?(unrelated_emp.id)).to be false
    end
  end
end
