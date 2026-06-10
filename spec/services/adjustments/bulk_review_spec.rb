require "rails_helper"

RSpec.describe Adjustments::BulkReview do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  # Accountant holds approve_adjustments (business-wide) and is NOT the creator below.
  let(:approver) { create(:user, :accountant, business: business) }
  let(:manager)  { create(:user, :branch_manager, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:period)   { create(:payroll_period, business: business, status: "draft") }

  def adjustment(creator: manager, status: :pending_review)
    create(:payroll_adjustment, :cash_incentive, payroll_period: period,
           business: business, user: employee, created_by: creator, review_status: status)
  end

  describe ".approve" do
    it "approves each pending adjustment individually with accurate audit fields" do
      a = adjustment
      b = adjustment

      result = described_class.approve(adjustments: [ a, b ], reviewer: approver)

      expect(result.succeeded).to eq(2)
      expect(result.skipped).to eq(0)
      expect(result.failed).to eq(0)

      [ a, b ].each do |adj|
        adj.reload
        expect(adj.review_status).to eq("approved")
        expect(adj.approved_by).to eq(approver)
        expect(adj.approved_at).to be_present
        expect(adj.reviewed_by).to eq(approver)
      end
    end

    it "skips records that are already approved" do
      already = adjustment(status: :approved)
      pending = adjustment

      result = described_class.approve(adjustments: [ already, pending ], reviewer: approver)

      expect(result.succeeded).to eq(1)
      expect(result.skipped).to eq(1)
      expect(result.failed).to eq(0)
    end

    it "fails (does not approve) a record the reviewer created themselves" do
      own = adjustment(creator: approver) # creator == reviewer → not permitted

      result = described_class.approve(adjustments: [ own ], reviewer: approver)

      expect(result.succeeded).to eq(0)
      expect(result.failed).to eq(1)
      expect(result.failures.first[:id]).to eq(own.id)
      expect(own.reload.review_status).to eq("pending_review")
    end

    it "processes the rest of the batch even when one row fails (no rollback)" do
      ok  = adjustment
      own = adjustment(creator: approver)

      result = described_class.approve(adjustments: [ ok, own ], reviewer: approver)

      expect(result.succeeded).to eq(1)
      expect(result.failed).to eq(1)
      expect(ok.reload.review_status).to eq("approved")
      expect(own.reload.review_status).to eq("pending_review")
    end

    it "reports the action and totals" do
      result = described_class.approve(adjustments: [ adjustment ], reviewer: approver)
      expect(result.action).to eq(:approve)
      expect(result.total).to eq(1)
      expect(result.any_succeeded?).to be true
    end
  end

  describe ".reject" do
    it "rejects each pending adjustment individually and records the note" do
      a = adjustment

      result = described_class.reject(adjustments: [ a ], reviewer: approver, notes: "Out of policy")

      expect(result.succeeded).to eq(1)
      expect(result.action).to eq(:reject)
      a.reload
      expect(a.review_status).to eq("rejected")
      expect(a.rejected_by).to eq(approver)
      expect(a.review_notes).to eq("Out of policy")
    end

    it "skips records that are already rejected" do
      already = adjustment(status: :rejected)

      result = described_class.reject(adjustments: [ already ], reviewer: approver)

      expect(result.succeeded).to eq(0)
      expect(result.skipped).to eq(1)
    end
  end
end
