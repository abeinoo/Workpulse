require "rails_helper"

RSpec.describe BranchScope, type: :service do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }

  let!(:branch)       { create(:branch, business: business) }
  let!(:other_branch) { create(:branch, business: business) }

  let(:area_manager)   { create(:user, business: business) }
  let(:branch_manager) { create(:user, business: business) }
  let(:staff)          { create(:user, business: business) } # shift-assigned only, manages nothing

  let(:hour_based_shift) { create(:shift, :hour_based, business: business) }

  before do
    branch.update_columns(area_manager_id: area_manager.id, branch_manager_id: branch_manager.id)
  end

  describe "management-based resolution (default, include_shift_assignments: false)" do
    it "branch scope returns branches the user branch-manages" do
      result = described_class.new(branch_manager).for_scope("branch")
      expect(result).to contain_exactly(branch.id)
    end

    it "area scope returns branches the user area-manages" do
      result = described_class.new(area_manager).for_scope("area")
      expect(result).to contain_exactly(branch.id)
    end

    it "business scope returns every branch in the business" do
      result = described_class.new(branch_manager).for_scope("business")
      expect(result).to include(branch.id, other_branch.id)
    end

    it "ignores an active ShiftAssignment when include_shift_assignments is false" do
      create(:shift_assignment, user: staff, branch: branch, shift: hour_based_shift)
      expect(described_class.new(staff).for_scope("branch")).to be_empty
    end

    it "self scope always returns no branches" do
      expect(described_class.new(branch_manager).for_scope("self")).to be_empty
    end

    it "owner's default_ids is every branch in the business" do
      expect(described_class.new(owner).default_ids).to include(branch.id, other_branch.id)
    end
  end

  describe "shift-assignment-aware resolution (include_shift_assignments: true)" do
    def scope_for(user, scope_name)
      described_class.new(user, include_shift_assignments: true).for_scope(scope_name)
    end

    context "branch scope" do
      it "resolves the user's branch from their active ShiftAssignment" do
        create(:shift_assignment, user: staff, branch: branch, shift: hour_based_shift)
        expect(scope_for(staff, "branch")).to contain_exactly(branch.id)
      end

      it "still includes management-based branches alongside shift-assignment ones" do
        create(:shift_assignment, user: branch_manager, branch: other_branch, shift: hour_based_shift)
        expect(scope_for(branch_manager, "branch")).to contain_exactly(branch.id, other_branch.id)
      end
    end

    context "region (area) scope" do
      it "resolves every branch sharing an area manager with the user's shift-assigned branch" do
        sibling_branch = create(:branch, business: business, area_manager_id: area_manager.id)
        create(:shift_assignment, user: staff, branch: branch, shift: hour_based_shift)

        result = scope_for(staff, "area")
        expect(result).to include(branch.id, sibling_branch.id)
        expect(result).not_to include(other_branch.id)
      end

      it "is empty when the shift-assigned branch has no area manager" do
        unmanaged_branch = create(:branch, business: business, area_manager_id: nil)
        create(:shift_assignment, user: staff, branch: unmanaged_branch, shift: hour_based_shift)

        expect(scope_for(staff, "area")).to be_empty
      end
    end

    context "organization (business) scope" do
      it "returns every branch regardless of shift assignment" do
        create(:shift_assignment, user: staff, branch: branch, shift: hour_based_shift)
        expect(scope_for(staff, "business")).to include(branch.id, other_branch.id)
      end
    end

    context "user with multiple active assignments" do
      it "includes every branch from every concurrently active ShiftAssignment" do
        third_branch = create(:branch, business: business)
        create(:shift_assignment, user: staff, branch: branch, shift: hour_based_shift)
        create(:shift_assignment, user: staff, branch: third_branch, shift: hour_based_shift)

        expect(scope_for(staff, "branch")).to contain_exactly(branch.id, third_branch.id)
      end
    end

    context "user without any active assignment" do
      it "branch scope is empty for a user who manages nothing and has no active assignment" do
        expect(scope_for(staff, "branch")).to be_empty
      end

      it "does not resolve an expired assignment" do
        create(:shift_assignment, user: staff, branch: branch, shift: hour_based_shift,
               effective_from: 6.months.ago.to_date, effective_to: 1.month.ago.to_date)
        expect(scope_for(staff, "branch")).to be_empty
      end

      it "does not resolve a not-yet-started (future) assignment" do
        create(:shift_assignment, user: staff, branch: branch, shift: hour_based_shift,
               effective_from: 1.month.from_now.to_date, effective_to: nil)
        expect(scope_for(staff, "branch")).to be_empty
      end
    end
  end
end
