require "rails_helper"

RSpec.describe PerformanceReview do
  let(:business)  { create(:business) }
  let(:department) { create(:department, business: business) }
  let(:employee)  { create(:user, business: business, department: department) }
  let(:reviewer)  { create(:user, business: business) }

  describe "snapshotting branch/department on create" do
    it "captures the employee's current branch from their active ShiftAssignment" do
      branch = create(:branch, business: business)
      shift  = create(:shift, :fixed_time, business: business)
      create(:shift_assignment, user: employee, branch: branch, shift: shift)

      review = create(:performance_review, business: business, department: department,
        employee: employee, reviewer: reviewer)

      expect(review.branch_id).to eq(branch.id)
    end

    it "leaves branch_id nil when the employee has no active ShiftAssignment" do
      review = create(:performance_review, business: business, department: department,
        employee: employee, reviewer: reviewer)

      expect(review.branch_id).to be_nil
    end

    it "does not re-snapshot on update, even if the employee moves branches later" do
      branch_a = create(:branch, business: business)
      branch_b = create(:branch, business: business)
      shift    = create(:shift, :fixed_time, business: business)
      assignment = create(:shift_assignment, user: employee, branch: branch_a, shift: shift)

      review = create(:performance_review, business: business, department: department,
        employee: employee, reviewer: reviewer)
      expect(review.branch_id).to eq(branch_a.id)

      assignment.update!(branch: branch_b)
      review.update!(notes: "updated")

      expect(review.reload.branch_id).to eq(branch_a.id)
    end

    it "defaults department_id from the employee when not explicitly set" do
      review = PerformanceReview.new(business: business, employee: employee, reviewer: reviewer,
        review_year: 2026, review_month: 1)
      review.valid?

      expect(review.department_id).to eq(department.id)
    end
  end
end
