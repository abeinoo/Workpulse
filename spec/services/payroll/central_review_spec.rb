require "rails_helper"

# The central payroll review: one slot with no branch for a period's floating
# employees, created on submission, completed (or sent back) by business-level
# reviewers only, and required before the period can be finalized — the
# under_review override included. Branch review slots behave exactly as before.
RSpec.describe "Payroll central review" do
  let(:business) { create(:business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:shift)    { create(:shift, :hour_based, business: business) }
  let(:period)   { create(:payroll_period, business: business, period_year: 2026, period_month: 10) }

  let(:floating_employee) { create(:user, business: business) }
  let(:branch_employee)   { create(:user, business: business) }

  def role(permissions, scopes = {})
    create(:permission_role, business: business, permissions: permissions, permission_scopes: scopes)
  end

  let(:accountant)        { create(:user, business: business, permission_role: role(%w[view_payroll submit_payroll_review finalize_payroll])) }
  let(:central_reviewer)  { create(:user, business: business, permission_role: role(%w[view_payroll complete_branch_review], "complete_branch_review" => "business")) }
  let(:branch_manager)    { create(:user, business: business, permission_role: role(%w[view_payroll complete_branch_review])) }
  let(:area_manager)      { create(:user, business: business, permission_role: role(%w[view_payroll complete_branch_review], "complete_branch_review" => "area")) }

  before do
    branch_a.update!(branch_manager: branch_manager, area_manager: area_manager)
    create(:shift_assignment, :floating, user: floating_employee, shift: shift, effective_from: Date.new(2026, 1, 1))
    create(:shift_assignment, user: branch_employee, shift: shift, branch: branch_a, effective_from: Date.new(2026, 1, 1))
    create(:payroll_entry, payroll_period: period, user: floating_employee, needs_review: true)
    create(:payroll_entry, payroll_period: period, user: branch_employee, needs_review: true)
  end

  def submit = Payroll::SubmitForReview.call(period: period, by: accountant)
  def central = period.payroll_period_branch_reviews.central.sole
  def complete(branch, by:) = Payroll::BranchReviewCompleter.call(period: period.reload, branch: branch, reviewer: by)

  describe "submission" do
    it "opens a pending central slot with no reviewer next to the unchanged branch slot" do
      expect(submit).to be_success

      expect(central).to have_attributes(status: "pending", reviewer_id: nil, completed_at: nil)
      expect(period.payroll_period_branch_reviews.where.not(branch_id: nil).sole)
        .to have_attributes(branch_id: branch_a.id, reviewer_id: branch_manager.id, status: "pending")
    end

    it "opens no central slot when the period has no floating employee" do
      ShiftAssignment.floating.update_all(effective_to: Date.new(2026, 9, 30))

      submit

      expect(period.payroll_period_branch_reviews.central).to be_empty
      expect(period.payroll_period_branch_reviews.count).to eq(1)
    end

    it "keeps one central slot per period, in the model and in the database" do
      submit

      expect(build(:payroll_period_branch_review, :central, payroll_period: period)).not_to be_valid
      expect {
        PayrollPeriodBranchReview.insert_all!([ { payroll_period_id: period.id, branch_id: nil, reviewer_id: nil,
                                                  status: "pending", created_at: Time.current, updated_at: Time.current } ])
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "still requires a reviewer on a branch slot" do
      expect(build(:payroll_period_branch_review, payroll_period: period, branch: branch_a, reviewer: nil)).not_to be_valid
    end

    it "adds the central slot on resubmission when a floating employee joined after the first submission" do
      ShiftAssignment.floating.update_all(effective_to: Date.new(2026, 9, 30))
      submit
      Payroll::ChangesRequester.call(period: period.reload, branch: branch_a, reviewer: branch_manager, comment: "Fix")
      ShiftAssignment.floating.update_all(effective_to: nil)

      expect(Payroll::SubmitForReview.call(period: period.reload, by: accountant)).to be_success
      expect(central).to be_pending
    end
  end

  describe "completion" do
    before { submit }

    it "is completed by a business-level reviewer, who is recorded with the time" do
      travel_to(Time.zone.local(2026, 11, 5, 10, 0)) do
        expect(complete(nil, by: central_reviewer)).to be_success
      end

      expect(central).to have_attributes(status: "completed", reviewer_id: central_reviewer.id,
                                         completed_at: Time.zone.local(2026, 11, 5, 10, 0))
      expect(PayrollEntry.find_by!(user: floating_employee).needs_review).to be(false)
      expect(PayrollEntry.find_by!(user: branch_employee).needs_review).to be(true)
    end

    it "is completed by the business owner" do
      owner = create(:user, business: business).tap { |u| business.update!(owner: u) }

      expect(complete(nil, by: owner)).to be_success
    end

    it "refuses branch and area managers, and leaves the slot untouched" do
      [ branch_manager, area_manager ].each do |manager|
        result = complete(nil, by: manager)

        expect(result).not_to be_success
        expect(result.error).to eq(I18n.t("payroll.errors.central_review_not_allowed"))
      end
      expect(central).to have_attributes(status: "pending", reviewer_id: nil)
    end

    it "refuses changes requested on it by a branch manager, and records a business reviewer's request" do
      refused = Payroll::ChangesRequester.call(period: period, branch: nil, reviewer: branch_manager, comment: "No")
      expect(refused).not_to be_success

      result = Payroll::ChangesRequester.call(period: period, branch: nil, reviewer: central_reviewer, comment: "Check overtime")
      expect(result).to be_success
      expect(central).to have_attributes(status: "changes_requested", reviewer_id: central_reviewer.id, notes: "Check overtime")
      meta = JSON.parse(period.payroll_audit_logs.where(action_type: "branch_changes_requested").last.metadata)
      expect(meta).to eq("branch_id" => nil, "central" => true, "comment" => "Check overtime")
    end

    it "keeps the branch slot's own flow: its manager completes it and the audit metadata is unchanged" do
      Payroll::ChangesRequester.call(period: period, branch: branch_a, reviewer: branch_manager, comment: "Fix")
      meta = JSON.parse(period.payroll_audit_logs.where(action_type: "branch_changes_requested").last.metadata)
      expect(meta).to eq("branch_id" => branch_a.id, "branch_name" => branch_a.name, "comment" => "Fix")
    end

    it "advances the period only once both the branch and the central slot are completed" do
      complete(branch_a, by: branch_manager)
      expect(period.reload).to be_under_review
      expect(period).not_to be_all_branches_reviewed

      complete(nil, by: central_reviewer)
      expect(period.reload).to be_branch_review_completed
    end
  end

  describe "finalization" do
    before { submit }

    def finalize = Payroll::Approver.advance(period: period.reload, by: accountant)

    it "refuses the under_review override while the central review is pending" do
      result = finalize

      expect(result).not_to be_success
      expect(result.error).to eq(I18n.t("payroll.errors.central_review_pending_finalize"))
      expect(period.reload).to be_under_review
    end

    it "keeps the override for pending branch slots once the central review is completed" do
      complete(nil, by: central_reviewer)

      expect(finalize).to be_success
      expect(period.reload).to be_finalized
    end

    it "finalizes normally after every review" do
      complete(branch_a, by: branch_manager)
      complete(nil, by: central_reviewer)

      expect(finalize).to be_success
    end

    it "never finalizes floating employees without a central slot: it is recreated and required" do
      period.payroll_period_branch_reviews.central.delete_all

      result = finalize

      expect(result).not_to be_success
      expect(result.error).to eq(I18n.t("payroll.errors.central_review_pending_finalize"))
      expect(central).to be_pending
      expect(period.reload).to be_under_review
    end

    it "still allows the override for a period with no floating employee and no central slot" do
      ShiftAssignment.floating.update_all(effective_to: Date.new(2026, 9, 30))
      period.payroll_period_branch_reviews.central.delete_all

      expect(finalize).to be_success
    end
  end
end
