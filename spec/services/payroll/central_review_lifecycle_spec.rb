require "rails_helper"

# Payroll::CentralReview keeps the central review in step with the period's
# floating payroll after submission: floating employees who appear later open
# it (and send a branch-review-completed period back to review), changed
# floating payroll reopens a completed one, unrelated changes never do, and
# finalization — the under_review override included — always requires it to be
# current. Every completion is its own audit event.
RSpec.describe Payroll::CentralReview do
  let(:business) { create(:business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:shift)    { create(:shift, :hour_based, business: business) }
  let(:period)   { create(:payroll_period, business: business, period_year: 2026, period_month: 10) }

  def role(permissions, scopes = {})
    create(:permission_role, business: business, permissions: permissions, permission_scopes: scopes)
  end

  let(:accountant)       { create(:user, business: business, permission_role: role(%w[view_payroll submit_payroll_review finalize_payroll])) }
  let(:central_reviewer) { create(:user, business: business, permission_role: role(%w[view_payroll complete_branch_review], "complete_branch_review" => "business")) }
  let(:branch_manager)   { create(:user, business: business, permission_role: role(%w[view_payroll complete_branch_review])) }

  let(:branch_employee)   { create(:user, business: business) }
  let(:floating_employee) { create(:user, business: business) }
  let!(:branch_entry)     { create(:payroll_entry, payroll_period: period, user: branch_employee, net_salary: 1_000) }

  before do
    branch_a.update!(branch_manager: branch_manager)
    create(:shift_assignment, user: branch_employee, shift: shift, branch: branch_a, effective_from: Date.new(2026, 1, 1))
  end

  def central_slot  = period.payroll_period_branch_reviews.central.first
  def branch_slot   = period.payroll_period_branch_reviews.find_by!(branch: branch_a)
  def submit        = Payroll::SubmitForReview.call(period: period.reload, by: accountant)
  def finalize      = Payroll::Approver.advance(period: period.reload, by: accountant)
  def complete(branch, by:) = Payroll::BranchReviewCompleter.call(period: period.reload, branch: branch, reviewer: by)
  def logs(type)    = period.payroll_audit_logs.where(action_type: type).order(:id)

  describe "floating employees appearing after the branch reviews completed" do
    before do
      submit
      complete(branch_a, by: branch_manager)
    end

    def expect_central_review_opened
      expect(period.reload).to be_branch_review_completed
      expect(described_class.new(period)).not_to be_current

      result = finalize

      expect(result).not_to be_success
      expect(result.error).to eq(I18n.t("payroll.errors.central_review_pending_finalize"))
      expect(period.reload).to be_under_review
      expect(central_slot).to have_attributes(status: "pending", reviewer_id: nil, completed_at: nil)
      expect(branch_slot).to be_completed # branch sign-offs are kept
      event = logs("central_review_reopened").sole
      expect(event).to have_attributes(actor_id: accountant.id, from_status: "branch_review_completed", to_status: "under_review")
      expect(event.metadata_hash).to include("reason" => "floating_employees_added", "floating_employee_count" => 1)
    end

    it "opens the central review when an employee of the period becomes floating (assignment change)" do
      ShiftAssignment.where(user: branch_employee).update_all(effective_to: Date.new(2026, 10, 14))
      create(:shift_assignment, :floating, user: branch_employee, shift: shift, effective_from: Date.new(2026, 10, 15))

      expect_central_review_opened
    end

    it "opens the central review when a floating employee's entry is created (entry creation / recalculation)" do
      create(:shift_assignment, :floating, user: floating_employee, shift: shift, effective_from: Date.new(2026, 1, 1))
      create(:payroll_entry, payroll_period: period, user: floating_employee)

      expect_central_review_opened
    end

    it "keeps refusing, without a second slot, until the central review is approved — then finalizes" do
      create(:shift_assignment, :floating, user: floating_employee, shift: shift, effective_from: Date.new(2026, 1, 1))
      create(:payroll_entry, payroll_period: period, user: floating_employee)

      2.times { expect(finalize).not_to be_success }
      expect(period.payroll_period_branch_reviews.central.count).to eq(1)

      complete(nil, by: central_reviewer)
      expect(period.reload).to be_branch_review_completed
      expect(finalize).to be_success
    end
  end

  describe "changes after the central review was approved" do
    let!(:floating_assignment) do
      create(:shift_assignment, :floating, user: floating_employee, shift: shift, effective_from: Date.new(2026, 1, 1))
    end
    let!(:floating_entry) { create(:payroll_entry, payroll_period: period, user: floating_employee, net_salary: 2_000) }

    before do
      submit
      complete(branch_a, by: branch_manager)
      complete(nil, by: central_reviewer)
    end

    def expect_reopened_by_finalization
      expect(described_class.new(period)).to be_stale
      expect(finalize).not_to be_success
      expect(central_slot).to have_attributes(status: "pending", reviewer_id: nil, completed_at: nil)
      expect(period.reload).to be_under_review
      expect(logs("central_review_reopened").sole.metadata_hash).to include("reason" => "content_changed")
      expect(logs("review_slot_completed").count).to eq(2) # the earlier approvals stay in the history
    end

    it "starts current and finalizes when nothing changed" do
      expect(period.reload).to be_branch_review_completed
      expect(described_class.new(period)).to be_current
      expect(finalize).to be_success
    end

    it "reopens when a floating employee's salary changes" do
      floating_entry.update_columns(base_salary: 2_500, net_salary: 2_500)

      expect_reopened_by_finalization
    end

    it "reopens when an adjustment is added, or a deduction waived, on a floating employee's payroll" do
      item = create(:payroll_line_item, payroll_entry: floating_entry, amount: -50, review_status: :approved)
      expect_reopened_by_finalization

      complete(nil, by: central_reviewer)
      expect(described_class.new(period.reload)).to be_current
      item.update_columns(deduction_waived: true)
      expect(described_class.new(period)).to be_stale
    end

    it "reopens when an overtime override changes the floating employee's payable figures" do
      floating_entry.update_columns(total_overtime: 150)

      expect_reopened_by_finalization
    end

    it "reopens when the floating employee leaves the scope (assignment change or entry removed)" do
      floating_assignment.update_columns(effective_from: Date.new(2026, 11, 1))

      expect_reopened_by_finalization
    end

    it "does not reopen for a branch-only change, nor for marking entries reviewed" do
      branch_entry.update_columns(net_salary: 1_500)
      floating_entry.update_columns(needs_review: true)
      floating_entry.update_columns(needs_review: false)

      expect(described_class.new(period.reload)).to be_current
      expect(finalize).to be_success
      expect(logs("central_review_reopened")).to be_empty
    end

    it "reopens on resubmission when the content changed meanwhile" do
      period.update!(status: :under_review)
      branch_slot.update_columns(status: "changes_requested") # the branch asked for changes
      floating_entry.update_columns(net_salary: 2_100)

      submit

      expect(central_slot).to be_pending
      expect(logs("central_review_reopened").sole.metadata_hash).to include("reason" => "content_changed")
    end
  end

  describe "#sync!" do
    before do
      create(:shift_assignment, :floating, user: floating_employee, shift: shift, effective_from: Date.new(2026, 1, 1))
      create(:payroll_entry, payroll_period: period, user: floating_employee)
    end

    it "changes nothing for a draft or a locked period" do
      expect(described_class.new(period).sync!(actor: accountant)).not_to be_changed

      period.update_columns(status: "finalized")
      expect(described_class.new(period.reload).sync!(actor: accountant)).not_to be_changed
      expect(period.payroll_period_branch_reviews).to be_empty
    end

    it "is idempotent: one slot, one event" do
      period.update_columns(status: "under_review")

      results = 2.times.map { described_class.new(period.reload).sync!(actor: accountant) }

      expect(results.map(&:changed?)).to eq([ true, false ])
      expect(period.payroll_period_branch_reviews.central.count).to eq(1)
      expect(logs("central_review_reopened").count).to eq(1)
    end
  end

  describe "audit history" do
    before do
      create(:shift_assignment, :floating, user: floating_employee, shift: shift, effective_from: Date.new(2026, 1, 1))
      create(:payroll_entry, payroll_period: period, user: floating_employee)
      submit
    end

    it "records a central completion while the branch slot is still open" do
      travel_to(Time.zone.local(2026, 11, 5, 9, 30)) { complete(nil, by: central_reviewer) }

      event = logs("review_slot_completed").sole
      expect(event.actor).to eq(central_reviewer)
      expect(event.metadata_hash).to include("central" => true, "completed_at" => Time.zone.local(2026, 11, 5, 9, 30).iso8601)
      expect(event.metadata_hash["scope_digest"]).to eq(described_class.new(period).scope_digest)
      expect(period.reload).to be_under_review
      expect(logs("branch_review_completed")).to be_empty
    end

    it "records a branch completion while the central slot is still open" do
      complete(branch_a, by: branch_manager)

      event = logs("review_slot_completed").sole
      expect(event.actor).to eq(branch_manager)
      expect(event.metadata_hash).to include("branch_id" => branch_a.id, "branch_name" => branch_a.name, "central" => false)
      expect(period.reload).to be_under_review
    end

    it "keeps requester, comment, resubmission and completer through request → resubmit → complete" do
      other_reviewer = create(:user, business: business, permission_role: central_reviewer.permission_role)

      Payroll::ChangesRequester.call(period: period, branch: nil, reviewer: central_reviewer, comment: "Check overtime")
      expect(central_slot).to have_attributes(status: "changes_requested", reviewer_id: central_reviewer.id)

      submit
      expect(central_slot).to have_attributes(status: "pending", reviewer_id: nil, completed_at: nil, notes: nil)

      complete(nil, by: other_reviewer)
      expect(central_slot).to have_attributes(status: "completed", reviewer_id: other_reviewer.id)

      history = period.payroll_audit_logs.order(:id).map { |l| [ l.action_type, l.actor_id ] }
      expect(history).to include([ "branch_changes_requested", central_reviewer.id ], [ "resubmitted_for_review", accountant.id ],
                                 [ "review_slot_completed", other_reviewer.id ])
      expect(logs("branch_changes_requested").sole.metadata_hash).to include("comment" => "Check overtime", "central" => true)
    end

    it "gives a resubmitted branch slot back to its branch manager, not the requester" do
      Payroll::ChangesRequester.call(period: period, branch: branch_a, reviewer: central_reviewer, comment: "Fix")
      expect(branch_slot.reviewer_id).to eq(central_reviewer.id)

      submit

      expect(branch_slot).to have_attributes(status: "pending", reviewer_id: branch_manager.id)
    end
  end
end
