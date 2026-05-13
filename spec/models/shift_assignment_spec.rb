require "rails_helper"

RSpec.describe ShiftAssignment, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:shift) }
    it { is_expected.to belong_to(:branch).optional }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:effective_from) }

    describe "effective_to_after_effective_from" do
      it "is invalid when effective_to equals effective_from" do
        date = Date.current
        assignment = build(:shift_assignment, effective_from: date, effective_to: date)
        expect(assignment).not_to be_valid
        expect(assignment.errors[:effective_to]).to be_present
      end

      it "is invalid when effective_to is before effective_from" do
        assignment = build(:shift_assignment,
                           effective_from: Date.current,
                           effective_to:   Date.current - 1.day)
        expect(assignment).not_to be_valid
      end

      it "is valid when effective_to is after effective_from" do
        assignment = build(:shift_assignment,
                           effective_from: Date.current,
                           effective_to:   Date.current + 30.days)
        expect(assignment).to be_valid
      end

      it "is valid when effective_to is nil (open-ended)" do
        assignment = build(:shift_assignment, effective_to: nil)
        expect(assignment).to be_valid
      end
    end

    describe "no_overlapping_assignment" do
      let(:business)    { create(:business) }
      let(:user)        { create(:user,   business: business) }
      let(:branch)      { create(:branch, business: business) }
      let(:shift)       { create(:shift,  business: business) }

      before do
        create(:shift_assignment,
               user:           user,
               branch:         branch,
               shift:          shift,
               effective_from: Date.new(2025, 1, 1),
               effective_to:   Date.new(2025, 6, 30))
      end

      it "rejects an overlapping assignment for the same user and branch" do
        overlap = build(:shift_assignment,
                        user:           user,
                        branch:         branch,
                        shift:          shift,
                        effective_from: Date.new(2025, 3, 1),
                        effective_to:   nil)
        expect(overlap).not_to be_valid
        expect(overlap.errors[:base]).to be_present
      end

      it "allows a non-overlapping assignment for the same user and branch" do
        non_overlap = build(:shift_assignment,
                            user:           user,
                            branch:         branch,
                            shift:          shift,
                            effective_from: Date.new(2025, 7, 1),
                            effective_to:   nil)
        expect(non_overlap).to be_valid
      end

      it "allows an overlapping assignment for a different branch" do
        other_branch = create(:branch, business: business)
        no_conflict = build(:shift_assignment,
                            user:           user,
                            branch:         other_branch,
                            shift:          shift,
                            effective_from: Date.new(2025, 3, 1))
        expect(no_conflict).to be_valid
      end
    end
  end

  describe "scopes" do
    let(:business)    { create(:business) }
    let(:user)        { create(:user,   business: business) }
    let(:branch)      { create(:branch, business: business) }
    let(:shift)       { create(:shift,  business: business) }

    let!(:active_now) do
      create(:shift_assignment, user: user, branch: branch, shift: shift,
             effective_from: 1.month.ago.to_date, effective_to: nil)
    end
    let!(:past) do
      create(:shift_assignment, user: create(:user, business: business),
             branch: branch, shift: shift,
             effective_from: 6.months.ago.to_date,
             effective_to:   2.months.ago.to_date)
    end
    let!(:future) do
      create(:shift_assignment, user: create(:user, business: business),
             branch: branch, shift: shift,
             effective_from: 1.month.from_now.to_date,
             effective_to:   nil)
    end

    describe ".active_on" do
      it "returns assignments active on the given date" do
        expect(ShiftAssignment.active_on(Date.current)).to include(active_now)
        expect(ShiftAssignment.active_on(Date.current)).not_to include(past, future)
      end
    end

    describe ".current" do
      it "returns assignments active today" do
        expect(ShiftAssignment.current).to include(active_now)
        expect(ShiftAssignment.current).not_to include(past, future)
      end
    end
  end

  describe "delegations" do
    it "delegates shift_name to shift#name" do
      assignment = build(:shift_assignment)
      expect(assignment.shift_name).to eq(assignment.shift.name)
    end

    it "delegates branch_name to branch#name" do
      assignment = build(:shift_assignment)
      expect(assignment.branch_name).to eq(assignment.branch.name)
    end
  end
end
