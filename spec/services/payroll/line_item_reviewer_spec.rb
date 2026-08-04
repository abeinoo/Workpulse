require "rails_helper"

RSpec.describe Payroll::LineItemReviewer do
  let(:business)  { create(:business) }
  let(:period)    { create(:payroll_period, business: business) }
  let(:employee)  { create(:user, business: business) }
  let(:manager)   { create(:user, :branch_manager, business: business) }
  let(:entry)     { create(:payroll_entry, payroll_period: period, user: employee, total_deductions: 50.0, net_salary: 4_950.0) }
  let(:line_item) { create(:payroll_line_item, :late_penalty, payroll_entry: entry) }

  describe ".call" do
    context "approving a pending deduction" do
      it "sets review_status to approved" do
        result = described_class.call(
          line_item:   line_item,
          action:      "approve",
          reviewed_by: manager,
          notes:       "Verified"
        )
        expect(result.success?).to be true
        expect(line_item.reload.review_status).to eq("approved")
        expect(line_item.reviewed_by).to eq(manager)
        expect(line_item.review_notes).to eq("Verified")
      end

      it "does not change entry totals on approval" do
        expect { described_class.call(line_item: line_item, action: "approve", reviewed_by: manager) }
          .not_to change { entry.reload.net_salary }
      end
    end

    context "rejecting a pending deduction" do
      it "sets review_status to rejected" do
        result = described_class.call(
          line_item:   line_item,
          action:      "reject",
          reviewed_by: manager,
          notes:       "Employee was not late"
        )
        expect(result.success?).to be true
        expect(line_item.reload.review_status).to eq("rejected")
      end

      it "reverses the deduction from entry totals" do
        described_class.call(line_item: line_item, action: "reject", reviewed_by: manager)
        entry.reload
        expect(entry.total_deductions).to eq(0.0)
        expect(entry.net_salary).to eq(5_000.0)
      end
    end

    context "with an invalid action" do
      it "returns failure" do
        result = described_class.call(line_item: line_item, action: "approve_all", reviewed_by: manager)
        expect(result.success?).to be false
        expect(result.error).to match(/invalid action/i)
      end

      it "no longer accepts 'waive' — waiving is Payroll::DeductionWaiver's job" do
        result = described_class.call(line_item: line_item, action: "waive", reviewed_by: manager, notes: "x")
        expect(result.success?).to be false
        expect(result.error).to match(/invalid action/i)
      end
    end

    context "when line item is not pending_review (for approve/reject)" do
      it "returns failure for already-approved items" do
        line_item.update!(review_status: "approved")
        result = described_class.call(line_item: line_item, action: "reject", reviewed_by: manager)
        expect(result.success?).to be false
      end
    end

    context "when payroll period is finalized" do
      let(:period) { create(:payroll_period, :finalized, business: business) }

      it "returns failure" do
        result = described_class.call(line_item: line_item, action: "approve", reviewed_by: manager)
        expect(result.success?).to be false
        expect(result.error).to match(/finalized/i)
      end
    end

    context "when payroll period is paid" do
      let(:period) { create(:payroll_period, :paid, business: business) }

      it "returns failure" do
        result = described_class.call(line_item: line_item, action: "approve", reviewed_by: manager)
        expect(result.success?).to be false
        expect(result.error).to match(/finalized/i)
      end
    end

    # ── Unified approval rule (Path D) ───────────────────────────────────────
    context "reviewer lacks approve_adjustments" do
      let(:no_perm_user) { create(:user, business: business) }

      it "is rejected with a permission error" do
        result = described_class.call(line_item: line_item, action: "approve", reviewed_by: no_perm_user)
        expect(result.success?).to be false
        expect(result.error).to eq(I18n.t("adjustments.errors.review_permission"))
        expect(line_item.reload.review_status).to eq("pending_review")
      end
    end

    context "adjustment-sourced line item" do
      let(:creator)  { create(:user, :accountant, business: business) }
      let(:approver) { create(:user, :accountant, business: business) }
      let(:adjustment) do
        create(:payroll_adjustment, :manual_deduction, payroll_period: period,
               user: employee, created_by: creator, review_status: :pending_review, amount: 100.0)
      end
      let(:sourced_item) do
        create(:payroll_line_item, payroll_entry: entry, item_type: :manual_deduction,
               amount: -100.0, review_status: :pending_review,
               source_type: "PayrollAdjustment", source_id: adjustment.id)
      end

      it "blocks the creator from approving their own item (creator != approver)" do
        result = described_class.call(line_item: sourced_item, action: "approve", reviewed_by: creator)
        expect(result.success?).to be false
        expect(result.error).to eq(I18n.t("adjustments.errors.review_own"))
        expect(sourced_item.reload.review_status).to eq("pending_review")
        expect(adjustment.reload.review_status).to eq("pending_review")
      end

      it "lets a different approver approve AND syncs the source adjustment" do
        result = described_class.call(line_item: sourced_item, action: "approve", reviewed_by: approver)
        expect(result.success?).to be true
        expect(sourced_item.reload.review_status).to eq("approved")

        adjustment.reload
        expect(adjustment.review_status).to eq("approved")
        expect(adjustment.approved_by).to eq(approver)
        expect(adjustment.approved_by).not_to eq(adjustment.created_by)
      end

      it "syncs a rejection back to the source adjustment" do
        described_class.call(line_item: sourced_item, action: "reject", reviewed_by: approver)
        expect(adjustment.reload.review_status).to eq("rejected")
        expect(adjustment.rejected_by).to eq(approver)
      end
    end
  end
end
