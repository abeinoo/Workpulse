require "rails_helper"

RSpec.describe Payroll::BranchReviewCompleter do
  let(:business) { create(:business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let(:manager)  { create(:user, :accountant, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }

  let(:employee_a) { create(:user, business: business) }
  let(:employee_b) { create(:user, business: business) }

  let(:period) { create(:payroll_period, business: business, status: :under_review) }

  let!(:review_a) { create(:payroll_period_branch_review, payroll_period: period, branch: branch_a, status: :pending) }
  let!(:review_b) { create(:payroll_period_branch_review, payroll_period: period, branch: branch_b, status: :pending) }

  let!(:entry_a) { create(:payroll_entry, payroll_period: period, user: employee_a, needs_review: true) }
  let!(:entry_b) { create(:payroll_entry, payroll_period: period, user: employee_b, needs_review: true) }

  before do
    create(:shift_assignment, user: employee_a, branch: branch_a, shift: shift, effective_from: 6.months.ago.to_date)
    create(:shift_assignment, user: employee_b, branch: branch_b, shift: shift, effective_from: 6.months.ago.to_date)
  end

  def run(branch:)
    described_class.call(period: period, branch: branch, reviewer: manager)
  end

  it "clears needs_review only for entries of employees in the branch being approved" do
    run(branch: branch_a)

    expect(entry_a.reload.needs_review?).to be false
    expect(entry_b.reload.needs_review?).to be true
  end

  it "does not clear needs_review for a branch whose review is still pending" do
    run(branch: branch_a)
    expect(entry_b.reload.needs_review?).to be true

    run(branch: branch_b)
    expect(entry_b.reload.needs_review?).to be false
  end

  it "writes an audit log for the cleared entry" do
    expect { run(branch: branch_a) }
      .to change { PayrollAuditLog.where(action_type: "entry_review_cleared").count }.by(1)
  end

  it "leaves an already-clear entry untouched" do
    entry_a.update!(needs_review: false)
    expect { run(branch: branch_a) }
      .not_to change { PayrollAuditLog.where(action_type: "entry_review_cleared").count }
  end

  it "still completes the branch review even when nothing needs clearing" do
    entry_a.update!(needs_review: false)
    result = run(branch: branch_a)

    expect(result.success?).to be true
    expect(review_a.reload.completed?).to be true
  end
end
