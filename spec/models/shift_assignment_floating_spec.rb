require "rails_helper"

# Floating assignments: an employee with no home branch (e.g. an area manager
# working across branches). Branch presence follows the assignment kind, the
# business check works without a branch, and a floating assignment never runs
# alongside another assignment of the same employee.
RSpec.describe ShiftAssignment, "floating" do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }

  def build_assignment(**attrs)
    build(:shift_assignment, user: employee, shift: shift, **attrs)
  end

  describe "branch by kind" do
    it "still requires a branch for a regular assignment" do
      assignment = build_assignment(branch: nil)

      expect(assignment).not_to be_valid
      expect(assignment.errors.details[:branch]).to eq([ { error: :blank } ]) # as belongs_to required
    end

    it "still requires a branch for temporary coverage" do
      assignment = build(:shift_assignment, :temporary_coverage, user: employee, shift: shift, branch: nil)

      expect(assignment).not_to be_valid
      expect(assignment.errors.details[:branch]).to eq([ { error: :blank } ]) # as belongs_to required
    end

    it "accepts a floating assignment with no branch" do
      expect(build(:shift_assignment, :floating, user: employee, shift: shift)).to be_valid
    end

    it "refuses a floating assignment with a branch" do
      assignment = build(:shift_assignment, :floating, user: employee, shift: shift)
      assignment.branch = branch

      expect(assignment).not_to be_valid
      expect(assignment.errors.of_kind?(:base, :floating_with_branch)).to be(true)
    end
  end

  describe "business ownership without a branch" do
    let(:other) { create(:business) }

    it "refuses a shift of another business" do
      assignment = build(:shift_assignment, :floating, user: employee, shift: create(:shift, :fixed_time, business: other))

      expect(assignment).not_to be_valid
      expect(assignment.errors.of_kind?(:shift_id, :other_business)).to be(true)
    end

    it "refuses a rule profile of another business" do
      assignment = build(:shift_assignment, :floating, user: employee, shift: shift,
                                                       rule_profile: create(:shift_rule_profile, business: other))

      expect(assignment).not_to be_valid
      expect(assignment.errors.of_kind?(:shift_rule_profile_id, :other_business)).to be(true)
    end

    it "accepts the employee's own business's shift and rule profile" do
      assignment = build(:shift_assignment, :floating, user: employee, shift: shift,
                                                       rule_profile: create(:shift_rule_profile, business: business))

      expect(assignment).to be_valid
    end
  end

  describe "no coexistence with another assignment" do
    it "refuses a floating assignment overlapping an open regular one" do
      create(:shift_assignment, user: employee, shift: shift, branch: branch, effective_from: 1.month.ago.to_date)
      assignment = build(:shift_assignment, :floating, user: employee, shift: shift, effective_from: Date.current)

      expect(assignment).not_to be_valid
      expect(assignment.errors.of_kind?(:base, :floating_overlaps_assignment)).to be(true)
    end

    it "refuses a regular assignment and temporary coverage overlapping a floating one" do
      create(:shift_assignment, :floating, user: employee, shift: shift, effective_from: 1.month.ago.to_date)

      regular  = build_assignment(branch: branch, effective_from: Date.current)
      coverage = build(:shift_assignment, :temporary_coverage, user: employee, shift: shift, branch: branch)

      [ regular, coverage ].each do |assignment|
        expect(assignment).not_to be_valid
        expect(assignment.errors.of_kind?(:base, :overlaps_floating_assignment)).to be(true)
      end
    end

    it "refuses two overlapping floating assignments with one error" do
      create(:shift_assignment, :floating, user: employee, shift: shift, effective_from: 1.month.ago.to_date)
      assignment = build(:shift_assignment, :floating, user: employee, shift: shift, effective_from: Date.current)

      expect(assignment).not_to be_valid
      expect(assignment.errors.map(&:type)).to eq([ :floating_overlaps_assignment ])
    end

    it "accepts a floating assignment starting after the regular one ends, and the reverse" do
      create(:shift_assignment, user: employee, shift: shift, branch: branch,
                                effective_from: 2.months.ago.to_date, effective_to: 1.month.ago.to_date)
      floating = create(:shift_assignment, :floating, user: employee, shift: shift,
                                                      effective_from: 1.month.ago.to_date + 1, effective_to: Date.current)

      expect(floating).to be_persisted
      expect(build_assignment(branch: branch, effective_from: Date.current + 1)).to be_valid
    end

    it "does not concern other employees" do
      create(:shift_assignment, :floating, user: employee, shift: shift)

      expect(build(:shift_assignment, user: create(:user, business: business), shift: shift, branch: branch)).to be_valid
    end
  end

  it "can be ended like any other assignment" do
    assignment = create(:shift_assignment, :floating, user: employee, shift: shift, effective_from: 1.month.ago.to_date)

    expect(assignment.update(effective_to: Date.current)).to be(true)
  end

  it "creates no branch membership" do
    create(:shift_assignment, :floating, user: employee, shift: shift)

    expect(BranchMembership.current_branch_ids(employee)).to eq([])
    expect(ShiftAssignment.user_ids_for_branches([ branch.id ]).pluck(:user_id)).not_to include(employee.id)
    expect(Shifts::AssignmentResolver.for(user: employee)).to be_floating
  end

  describe Shifts::Assigner do
    it "closes the employee's open regular assignments at every branch when switching to floating" do
      other_branch = create(:branch, business: business)
      first  = create(:shift_assignment, user: employee, shift: shift, branch: branch, effective_from: 2.months.ago.to_date)
      second = create(:shift_assignment, user: employee, branch: other_branch,
                                         shift: create(:shift, :hour_based, business: business),
                                         effective_from: 2.months.ago.to_date)

      result = described_class.call(business: business, params: {
        user_id: employee.id, shift_id: shift.id, effective_from: Date.current, assignment_kind: "floating"
      })

      expect(result).to be_success
      expect(result.assignment).to be_floating
      expect(result.assignment.branch_id).to be_nil
      expect([ first.reload.effective_to, second.reload.effective_to ]).to eq([ Date.current - 1, Date.current - 1 ])
    end

    it "keeps closing only the same branch's open assignment for a regular one" do
      other_branch = create(:branch, business: business)
      kept = create(:shift_assignment, user: employee, branch: other_branch,
                                       shift: create(:shift, :hour_based, business: business),
                                       effective_from: 2.months.ago.to_date)
      replaced = create(:shift_assignment, user: employee, shift: shift, branch: branch, effective_from: 2.months.ago.to_date)

      result = described_class.call(business: business, params: {
        user_id: employee.id, shift_id: shift.id, branch_id: branch.id, effective_from: Date.current
      })

      expect(result).to be_success
      expect(replaced.reload.effective_to).to eq(Date.current - 1)
      expect(kept.reload.effective_to).to be_nil
    end

    it "refuses a floating assignment for an employee of another business" do
      result = described_class.call(business: business, params: {
        user_id: create(:user).id, shift_id: shift.id, effective_from: Date.current, assignment_kind: "floating"
      })

      expect(result).not_to be_success
    end
  end
end
