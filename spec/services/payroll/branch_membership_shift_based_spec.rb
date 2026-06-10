require "rails_helper"

# Regression: branch membership is derived from active ShiftAssignment. Reproduces
# the production bug where "Branch Only" payroll scope returned no employees and the
# Complete Branch Review button never appeared. Every employee here is tied to their
# branch solely by an active ShiftAssignment.
RSpec.describe "Shift-driven branch membership", type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }

  # Branch manager with view_payroll scoped to branch_only + branch review rights.
  let(:role) do
    create(:permission_role, business: business,
           permissions: %w[view_payroll complete_branch_review create_payroll submit_payroll_review],
           permission_scopes: { "view_payroll" => "branch_only" })
  end
  let(:manager) { create(:user, business: business, permission_role: role) }

  # Shift-assigned to the branch → only an active ShiftAssignment ties them to it.
  let(:emp_shift_only)   { create(:user, business: business) }
  # A second employee also assigned to the manager's branch — must also appear.
  let(:emp_with_manager) { create(:user, business: business) }
  # In a different branch entirely — must NOT appear.
  let(:other_branch)     { create(:branch, business: business) }
  let(:emp_other_branch) { create(:user, business: business) }

  before do
    branch.update_columns(branch_manager_id: manager.id)
    create(:shift_assignment, user: emp_shift_only,   branch: branch,       shift: shift)
    create(:shift_assignment, user: emp_with_manager, branch: branch,       shift: shift)
    create(:shift_assignment, user: emp_other_branch, branch: other_branch, shift: shift)
  end

  describe "EmployeeScope#branch (Branch Only)" do
    subject(:ids) { EmployeeScope.new(manager).for_scope("branch_only").pluck(:id) }

    it "returns employees whose active ShiftAssignment is in the manager's branch" do
      expect(ids).to include(emp_shift_only.id, emp_with_manager.id)
    end

    it "excludes employees assigned to other branches" do
      expect(ids).not_to include(emp_other_branch.id)
    end

    it "returns an employee tied to the branch solely by an active ShiftAssignment" do
      expect(ids).to include(emp_shift_only.id)
    end
  end

  describe "EmployeeScope#relation (default hierarchy)" do
    it "returns employees assigned to the manager's branch" do
      expect(EmployeeScope.new(manager).relation.pluck(:id)).to include(emp_with_manager.id)
    end
  end

  describe "payroll visibility via PayrollEntryPolicy::Scope (scope = branch_only)" do
    let(:period) { create(:payroll_period, :last_month, business: business) }

    before do
      [ emp_shift_only, emp_with_manager, emp_other_branch ].each do |u|
        create(:payroll_entry, payroll_period: period, user: u)
      end
    end

    subject(:visible_user_ids) do
      PayrollEntryPolicy::Scope.new(manager, PayrollEntry.all).resolve.pluck(:user_id)
    end

    it "shows entries for shift-assigned branch employees" do
      expect(visible_user_ids).to include(emp_shift_only.id, emp_with_manager.id)
    end

    it "hides entries for employees in other branches" do
      expect(visible_user_ids).not_to include(emp_other_branch.id)
    end
  end

  describe "Complete Branch Review creation (Payroll::SubmitForReview)" do
    let(:period) { create(:payroll_period, business: business, status: :draft) }

    before do
      [ emp_shift_only, emp_with_manager ].each do |u|
        create(:payroll_entry, payroll_period: period, user: u)
      end
    end

    it "creates a branch review row for the shift-attributed branch" do
      result = Payroll::SubmitForReview.call(period: period, by: manager)
      expect(result).to be_success
      reviews = period.reload.payroll_period_branch_reviews
      expect(reviews.map(&:branch_id)).to include(branch.id)
      expect(reviews.find_by(branch: branch).reviewer_id).to eq(manager.id)
    end

    it "makes the branch review visible to the managing user (button precondition)" do
      Payroll::SubmitForReview.call(period: period, by: manager)
      # Mirrors PayrollPeriodsController#manager_branch_reviews + reviewable_branch_ids_for.
      reviewable = manager.managed_branch_ids + manager.area_managed_branch_ids
      visible = period.reload.payroll_period_branch_reviews.where(branch_id: reviewable)
      expect(visible).to be_present
      expect(visible.any? { |r| !r.completed? }).to be true
    end
  end
end
