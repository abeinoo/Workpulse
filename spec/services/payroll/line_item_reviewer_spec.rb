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

    context "waiving a pending deduction" do
      it "sets review_status to waived" do
        result = described_class.call(
          line_item:   line_item,
          action:      "waive",
          reviewed_by: manager,
          notes:       "Excused late arrival — traffic incident"
        )
        expect(result.success?).to be true
        expect(line_item.reload.review_status).to eq("waived")
        expect(line_item.reviewed_by).to eq(manager)
        expect(line_item.review_notes).to eq("Excused late arrival — traffic incident")
      end

      it "reverses the deduction from entry totals" do
        described_class.call(
          line_item:   line_item,
          action:      "waive",
          reviewed_by: manager,
          notes:       "Manager approved"
        )
        entry.reload
        expect(entry.total_deductions).to eq(0.0)
        expect(entry.net_salary).to eq(5_000.0)
      end

      it "records reviewed_at timestamp" do
        freeze_time do
          described_class.call(line_item: line_item, action: "waive", reviewed_by: manager, notes: "Approved")
          expect(line_item.reload.reviewed_at).to eq(Time.current)
        end
      end
    end

    context "waiving an already-approved deduction" do
      before { line_item.update!(review_status: "approved") }

      it "succeeds — managers can override confirmed deductions" do
        result = described_class.call(
          line_item:   line_item,
          action:      "waive",
          reviewed_by: manager,
          notes:       "Incorrect calculation approved in error"
        )
        expect(result.success?).to be true
        expect(line_item.reload.review_status).to eq("waived")
      end

      it "reverses the deduction from entry totals" do
        described_class.call(line_item: line_item, action: "waive", reviewed_by: manager, notes: "Override")
        entry.reload
        expect(entry.total_deductions).to eq(0.0)
        expect(entry.net_salary).to eq(5_000.0)
      end
    end

    context "waive with missing reason" do
      it "returns failure" do
        result = described_class.call(line_item: line_item, action: "waive", reviewed_by: manager, notes: nil)
        expect(result.success?).to be false
        expect(result.error).to match(/reason is required/i)
      end

      it "returns failure for blank reason" do
        result = described_class.call(line_item: line_item, action: "waive", reviewed_by: manager, notes: "   ")
        expect(result.success?).to be false
        expect(result.error).to match(/reason is required/i)
      end
    end

    context "waiving an already-rejected deduction" do
      before { line_item.update!(review_status: "rejected") }

      it "returns failure — deduction already removed" do
        result = described_class.call(line_item: line_item, action: "waive", reviewed_by: manager, notes: "Override")
        expect(result.success?).to be false
        expect(result.error).to match(/only active deductions/i)
      end
    end

    context "waiving an already-waived deduction" do
      before { line_item.update!(review_status: "waived") }

      it "returns failure" do
        result = described_class.call(line_item: line_item, action: "waive", reviewed_by: manager, notes: "Again")
        expect(result.success?).to be false
        expect(result.error).to match(/only active deductions/i)
      end
    end

    context "with an invalid action" do
      it "returns failure" do
        result = described_class.call(line_item: line_item, action: "approve_all", reviewed_by: manager)
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

      it "also blocks waive" do
        result = described_class.call(line_item: line_item, action: "waive", reviewed_by: manager, notes: "Try anyway")
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
  end
end
