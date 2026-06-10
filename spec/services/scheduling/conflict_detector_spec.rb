require "rails_helper"

RSpec.describe Scheduling::ConflictDetector do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }
  let(:user)     { create(:user, business: business) }

  let(:from) { Date.current }
  let(:to)   { Date.current + 30.days }

  def detect(**overrides)
    described_class.call(
      user:           overrides.fetch(:user, user),
      shift:          overrides.fetch(:shift, shift),
      branch:         overrides.fetch(:branch, branch),
      effective_from: overrides.fetch(:effective_from, from),
      effective_to:   overrides.fetch(:effective_to, to)
    )
  end

  describe "#call" do
    context "when the employee is active and no conflicts exist" do
      it "returns :valid status" do
        # The employee has prior (non-overlapping) history at the branch, so there
        # is no branch-mismatch warning and the new assignment is conflict-free.
        create(:shift_assignment, user: user, branch: branch, shift: shift,
               effective_from: 90.days.ago.to_date, effective_to: 60.days.ago.to_date)
        result = detect
        expect(result.status).to eq(:valid)
        expect(result.valid?).to be true
      end
    end

    context "when the employee is inactive" do
      before { user.update!(active: false) }

      it "returns :blocked status with :employee_inactive reason" do
        result = detect
        expect(result.blocked?).to be true
        expect(result.reason).to eq(:employee_inactive)
      end
    end

    context "when an overlapping assignment exists for the same user and branch" do
      before do
        create(:shift_assignment,
               user: user, branch: branch, shift: shift,
               effective_from: from - 10.days,
               effective_to:   nil)
      end

      it "returns :blocked status" do
        result = detect
        expect(result.blocked?).to be true
        expect(result.reason).to be_present
      end
    end

    context "when the employee is not in the branch" do
      it "returns :warning with :branch_mismatch reason (soft conflict)" do
        # user has no user_branch record for this branch
        result = detect
        expect(result.warning?).to be true
        expect(result.reason).to eq(:branch_mismatch)
      end
    end

    context "when branch is nil" do
      it "returns :valid even without a branch" do
        result = detect(branch: nil)
        expect(result.valid?).to be true
      end
    end
  end
end
