require "rails_helper"

# Characterization (R3.2 G0): Payroll::SubmitForReview as it behaves today,
# before the R3.2 payroll-status lock (gate G4). These pin current behaviour
# only; the examples marked "current behaviour" are the ones G4 is planned to
# change.
RSpec.describe Payroll::SubmitForReview do
  let(:business) { create(:business) }
  let(:shift)    { create(:shift, :hour_based, business: business) }
  let(:managed_branch)   { create(:branch, business: business) }
  let(:unmanaged_branch) { create(:branch, business: business) }
  let(:branch_manager)   { create(:user, business: business) }
  let(:actor)            { create(:user, business: business) }
  let(:period) { create(:payroll_period, business: business, period_year: 2026, period_month: 10) }

  let(:managed_employee)   { create(:user, business: business) }
  let(:unmanaged_employee) { create(:user, business: business) }

  before do
    managed_branch.update!(branch_manager: branch_manager)
    create(:shift_assignment, user: managed_employee, shift: shift, branch: managed_branch,
                              effective_from: Date.new(2026, 1, 1))
    create(:shift_assignment, user: unmanaged_employee, shift: shift, branch: unmanaged_branch,
                              effective_from: Date.new(2026, 1, 1))
    create(:payroll_entry, payroll_period: period, user: managed_employee)
    create(:payroll_entry, payroll_period: period, user: unmanaged_employee)
  end

  def submit(target = period) = described_class.call(period: target, by: actor)

  describe "initial submission of a draft period" do
    it "moves the period to under_review" do
      expect(submit).to be_success
      expect(period.reload).to be_under_review
    end

    it "opens a pending review slot, reviewed by the branch manager, only for branches with a manager" do
      submit
      reviews = period.reload.payroll_period_branch_reviews
      expect(reviews.map(&:branch_id)).to eq([ managed_branch.id ])
      expect(reviews.sole).to have_attributes(reviewer_id: branch_manager.id, status: "pending")
    end

    it "records one submitted_for_review payroll audit entry from draft to under_review" do
      expect { submit }.to change(PayrollAuditLog, :count).by(1)
      expect(PayrollAuditLog.last).to have_attributes(
        payroll_period_id: period.id, actor_id: actor.id, action_type: "submitted_for_review",
        from_status: "draft", to_status: "under_review"
      )
    end

    it "writes no AuditLog entry" do
      expect { submit }.not_to change(AuditLog, :count)
    end

    it "leaves the business's other payroll periods untouched" do
      other = create(:payroll_period, business: business, period_year: 2026, period_month: 9)
      submit
      expect(other.reload).to be_draft
    end

    it "is all-or-nothing: when the audit entry fails, the period stays draft with no review slots" do
      allow(PayrollAuditLog).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(PayrollAuditLog.new))

      result = submit
      expect(result).not_to be_success
      expect(result.error).to be_present
      expect(period.reload).to be_draft
      expect(period.payroll_period_branch_reviews).to be_empty
    end
  end

  describe "refusals" do
    let(:message) do
      "Period must be draft (initial submission) or under_review with changes requested (resubmission)"
    end

    %i[under_review branch_review_completed finalized paid].each do |status|
      it "refuses a #{status} period without changes requested, changing nothing" do
        period.update_column(:status, status.to_s)

        result = nil
        expect { result = submit(period.reload) }.not_to change(PayrollAuditLog, :count)
        expect(result).not_to be_success
        expect(result.error).to eq(message)
        expect(period.reload.status).to eq(status.to_s)
        expect(period.payroll_period_branch_reviews).to be_empty
      end
    end
  end

  describe "resubmission after changes were requested" do
    let!(:review) do
      period.update_column(:status, "under_review")
      create(:payroll_period_branch_review, payroll_period: period, branch: managed_branch,
                                            reviewer: actor, status: :changes_requested,
                                            notes: "Fix overtime", completed_at: Time.current)
    end

    it "keeps the period under_review and returns the slot to pending with the branch manager as reviewer" do
      expect(submit(period.reload)).to be_success
      expect(period.reload).to be_under_review
      expect(review.reload).to have_attributes(status: "pending", completed_at: nil, notes: nil,
                                               reviewer_id: branch_manager.id)
    end

    it "records one resubmitted_for_review payroll audit entry" do
      expect { submit(period.reload) }.to change(PayrollAuditLog, :count).by(1)
      expect(PayrollAuditLog.last).to have_attributes(action_type: "resubmitted_for_review", actor_id: actor.id)
    end
  end

  # Current behaviour, planned to change in G4: the service decides on the
  # status of the object it is given, without reloading or locking the row.
  # A stale in-memory draft whose row is already under_review is submitted
  # again (a second submitted_for_review entry is written).
  describe "stale period object (current behaviour)" do
    it "submits a stale draft object even though the row is already under_review" do
      stale = PayrollPeriod.find(period.id)
      expect(submit(PayrollPeriod.find(period.id))).to be_success

      expect(stale).to be_draft
      result = nil
      expect { result = submit(stale) }.to change(PayrollAuditLog.submitted_for_review, :count).by(1)
      expect(result).to be_success
      expect(period.reload).to be_under_review
      expect(period.payroll_period_branch_reviews.count).to eq(1)
    end
  end
end
