require "rails_helper"

RSpec.describe Payroll::AdjustmentEditor do
  let(:business) { create(:business) }
  let(:period)   { create(:payroll_period, business: business, status: "draft") }
  let(:employee) { create(:user, business: business) }
  let(:manager)  { create(:user, :branch_manager, business: business) }
  let(:editor) do
    role = create(:permission_role, business: business,
                  permissions: %w[view_adjustments manage_adjustments edit_approved_adjustments])
    create(:user, business: business, permission_role: role)
  end

  let!(:adjustment) do
    create(:payroll_adjustment, :cash_incentive, :approved,
           payroll_period: period,
           business:       business,
           user:           employee,
           created_by:     manager,
           amount:         500.0,
           reason:         "Original reason")
  end

  def call(params = {})
    described_class.call(
      adjustment_id: adjustment.id,
      actor:         editor,
      params:        { adjustment_type: "cash_incentive", amount: "600", reason: "Updated reason" }.merge(params)
    )
  end

  describe "happy path — approved adjustment in a draft period" do
    it "returns ok: true" do
      expect(call.ok?).to be true
    end

    it "resets the adjustment to pending_review" do
      call
      expect(adjustment.reload.review_status).to eq("pending_review")
    end

    it "updates the amount and reason" do
      call
      adjustment.reload
      expect(adjustment.amount).to eq(600.0)
      expect(adjustment.reason).to eq("Updated reason")
    end

    it "clears approved_by and approved_at" do
      call
      adjustment.reload
      expect(adjustment.approved_by_id).to be_nil
      expect(adjustment.approved_at).to be_nil
    end

    it "clears reviewed_by and reviewed_at" do
      call
      adjustment.reload
      expect(adjustment.reviewed_by_id).to be_nil
      expect(adjustment.reviewed_at).to be_nil
    end

    it "creates a PayrollAdjustmentEdit record with old/new snapshot" do
      expect { call }.to change(PayrollAdjustmentEdit, :count).by(1)
      edit = PayrollAdjustmentEdit.last
      expect(edit.edited_by).to eq(editor)
      expect(edit.old_amount).to eq(500.0)
      expect(edit.new_amount).to eq(600.0)
      expect(edit.old_reason).to eq("Original reason")
      expect(edit.new_reason).to eq("Updated reason")
    end
  end

  describe "when an existing PayrollEntry has a line item for the adjustment" do
    let!(:entry) do
      create(:payroll_entry,
             payroll_period:   period,
             user:             employee,
             base_salary:      5_000.0,
             net_salary:       5_500.0,
             total_bonuses:    500.0,
             total_deductions: 0.0)
    end
    let!(:line_item) do
      entry.payroll_line_items.create!(
        item_type:     "cash_incentive",
        amount:        500.0,
        description:   "Original reason",
        source_type:   "PayrollAdjustment",
        source_id:     adjustment.id,
        review_status: "approved"
      )
    end

    it "resets the line item to pending_review" do
      call
      expect(line_item.reload.review_status).to eq("pending_review")
    end

    it "updates the line item amount to the new value" do
      call
      expect(line_item.reload.amount).to eq(600.0)
    end

    it "recalculates entry totals — the pending line item is excluded" do
      call
      entry.reload
      expect(entry.total_bonuses).to eq(0.0)
      expect(entry.net_salary).to eq(5_000.0)
    end
  end

  describe "when the adjustment is pending_review (not approved)" do
    let!(:pending_adj) do
      create(:payroll_adjustment, :cash_incentive,
             payroll_period: period, business: business,
             user: employee, created_by: manager, amount: 300.0)
    end

    it "returns ok: false with :not_approved error" do
      result = described_class.call(
        adjustment_id: pending_adj.id,
        actor:         editor,
        params:        { amount: "400", reason: "x" }
      )
      expect(result.ok?).to be false
      expect(result.error).to eq(:not_approved)
    end
  end

  describe "when the period is finalized" do
    before { period.update_column(:status, "finalized") }

    it "returns ok: false with period_finalized error" do
      result = call
      expect(result.ok?).to be false
      expect(result.period_finalized?).to be true
    end

    it "does NOT modify the adjustment" do
      call
      adjustment.reload
      expect(adjustment.review_status).to eq("approved")
      expect(adjustment.amount).to eq(500.0)
    end
  end

  describe "when the period is paid" do
    before { period.update_column(:status, "paid") }

    it "returns period_finalized? true" do
      expect(call.period_finalized?).to be true
    end
  end

  describe "period change via period_key" do
    let!(:target_period) do
      create(:payroll_period, business: business,
             period_month: 6, period_year: 2026, status: "draft")
    end

    def call_with_period(new_period_key)
      described_class.call(
        adjustment_id: adjustment.id,
        actor:         editor,
        params:        { adjustment_type: "cash_incentive", amount: "500",
                         reason: "Same reason", period_key: new_period_key }
      )
    end

    it "updates period_month and period_year on the adjustment" do
      call_with_period("2026-6")
      adjustment.reload
      expect(adjustment.period_month).to eq(6)
      expect(adjustment.period_year).to eq(2026)
    end

    it "links payroll_period_id to the new period" do
      call_with_period("2026-6")
      expect(adjustment.reload.payroll_period_id).to eq(target_period.id)
    end

    it "records old and new period in the audit edit" do
      call_with_period("2026-6")
      edit = PayrollAdjustmentEdit.last
      expect(edit.old_period_month).to eq(adjustment.period_month)
      expect(edit.new_period_month).to eq(6)
      expect(edit.old_period_year).to eq(adjustment.period_year)
      expect(edit.new_period_year).to eq(2026)
    end

    context "when there is a line_item in the old period's entry" do
      let!(:old_entry) do
        create(:payroll_entry,
               payroll_period:   period,
               user:             employee,
               base_salary:      5_000.0,
               net_salary:       5_500.0,
               total_bonuses:    500.0,
               total_deductions: 0.0)
      end
      let!(:line_item) do
        old_entry.payroll_line_items.create!(
          item_type:     "cash_incentive",
          amount:        500.0,
          description:   "Original reason",
          source_type:   "PayrollAdjustment",
          source_id:     adjustment.id,
          review_status: "approved"
        )
      end

      it "destroys the old line_item" do
        call_with_period("2026-6")
        expect(PayrollLineItem.exists?(line_item.id)).to be false
      end

      it "recalculates the old entry's totals — bonus removed" do
        call_with_period("2026-6")
        old_entry.reload
        expect(old_entry.total_bonuses).to eq(0.0)
        expect(old_entry.net_salary).to eq(5_000.0)
      end
    end

    context "when the target period is locked (finalized)" do
      before { target_period.update_column(:status, "finalized") }

      it "returns ok: false with target_period_locked? true" do
        result = call_with_period("2026-6")
        expect(result.ok?).to be false
        expect(result.target_period_locked?).to be true
      end

      it "does not modify the adjustment" do
        call_with_period("2026-6")
        adjustment.reload
        expect(adjustment.review_status).to eq("approved")
        expect(adjustment.period_month).to eq(period.period_month)
      end
    end

    context "when the target period has no PayrollPeriod record (future month)" do
      it "accepts the period and sets payroll_period_id to nil" do
        result = call_with_period("2027-3")
        expect(result.ok?).to be true
        adjustment.reload
        expect(adjustment.period_month).to eq(3)
        expect(adjustment.period_year).to eq(2027)
        expect(adjustment.payroll_period_id).to be_nil
      end
    end
  end

  describe "type change — from cash_incentive to manual_deduction" do
    it "changes the adjustment_type and records it in the edit" do
      call(adjustment_type: "manual_deduction", amount: "200", reason: "Policy fine")
      adjustment.reload
      expect(adjustment.adjustment_type).to eq("manual_deduction")
      edit = PayrollAdjustmentEdit.last
      expect(edit.old_adjustment_type).to eq("cash_incentive")
      expect(edit.new_adjustment_type).to eq("manual_deduction")
    end
  end

  describe "audit log" do
    it "creates a PayrollAuditLog entry with action_type adjustment_edited" do
      expect { call }.to change(PayrollAuditLog, :count).by(1)
      log = PayrollAuditLog.last
      expect(log.action_type).to eq("adjustment_edited")
      expect(log.actor).to eq(editor)
      meta = log.metadata_hash
      expect(meta["old_amount"].to_f).to eq(500.0)
      expect(meta["new_amount"].to_f).to eq(600.0)
    end
  end

  describe "re-approval after edit via AdjustmentApplier" do
    let!(:entry) do
      create(:payroll_entry,
             payroll_period:   period,
             user:             employee,
             base_salary:      5_000.0,
             net_salary:       5_000.0,
             total_bonuses:    0.0)
    end
    let!(:line_item) do
      entry.payroll_line_items.create!(
        item_type:     "cash_incentive",
        amount:        500.0,
        source_type:   "PayrollAdjustment",
        source_id:     adjustment.id,
        review_status: "approved"
      )
    end

    it "does NOT duplicate the line item when AdjustmentApplier is called after re-approval" do
      call  # edit: demotes to pending
      # Re-approve using the editor (not the creator/manager — creator ≠ approver rule)
      adjustment.reload.approve_by!(editor)
      Payroll::AdjustmentApplier.call(adjustment: adjustment.reload)

      expect(entry.payroll_line_items.where(source_type: "PayrollAdjustment", source_id: adjustment.id).count).to eq(1)
    end

    it "updates the line item to the new amount after re-approval" do
      call  # edit: amount → 600, status → pending
      adjustment.reload.approve_by!(editor)
      Payroll::AdjustmentApplier.call(adjustment: adjustment.reload)

      line_item.reload
      expect(line_item.amount).to eq(600.0)
      expect(line_item.review_status).to eq("approved")
    end
  end
end
