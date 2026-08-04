require "rails_helper"

RSpec.describe Payroll::DeductionWaiver do
  let(:business) { create(:business) }
  let(:period)   { create(:payroll_period, business: business, status: :draft) }
  let(:employee) { create(:user, business: business) }
  let(:manager)  { create(:user, :accountant, business: business) }

  # Entry with base 5000 and one approved manual deduction of 100, backed by a
  # line item so recalculate_totals! keeps net_salary in sync.
  let(:entry) do
    create(:payroll_entry, payroll_period: period, user: employee,
           base_salary: 5_000.0, total_deductions: 100.0, net_salary: 4_900.0)
  end
  let!(:deduction) do
    create(:payroll_line_item, :manual_deduction, payroll_entry: entry, amount: -100.0)
  end

  describe "waive" do
    it "excludes the deduction from totals and raises net salary" do
      result = described_class.call(line_item: deduction, action: "waive", actor: manager, reason: "Goodwill")

      expect(result.success?).to be true
      deduction.reload
      expect(deduction.deduction_waived?).to be true
      expect(deduction.deduction_waived_by).to eq(manager)
      expect(deduction.deduction_waiver_reason).to eq("Goodwill")
      expect(deduction.deduction_waived_at).to be_present

      entry.reload
      expect(entry.total_deductions).to eq(0.0)
      expect(entry.net_salary).to eq(5_000.0)
    end

    it "does NOT modify the source adjustment / deduction record" do
      adjustment = create(:payroll_adjustment, :manual_deduction, payroll_period: period,
                          user: employee, amount: 100.0, review_status: "approved")
      deduction.update!(source_id: adjustment.id)

      described_class.call(line_item: deduction, action: "waive", actor: manager, reason: "x")

      expect(adjustment.reload.review_status).to eq("approved")
      expect(adjustment.amount).to eq(100.0)
    end

    it "requires a reason" do
      result = described_class.call(line_item: deduction, action: "waive", actor: manager, reason: " ")
      expect(result.success?).to be false
      expect(result.error).to eq(I18n.t("payroll.deduction_waiver.errors.reason_required"))
      expect(deduction.reload.deduction_waived?).to be false
    end

    it "rejects waiving a deduction that is already waived" do
      described_class.call(line_item: deduction, action: "waive", actor: manager, reason: "x")
      result = described_class.call(line_item: deduction, action: "waive", actor: manager, reason: "y")
      expect(result.success?).to be false
      expect(result.error).to eq(I18n.t("payroll.deduction_waiver.errors.already_waived"))
    end

    it "rejects a deduction type not on the waivable allowlist" do
      advance = create(:payroll_line_item, :advance_deduction, payroll_entry: entry, amount: -50.0)
      result = described_class.call(line_item: advance, action: "waive", actor: manager, reason: "x")
      expect(result.success?).to be false
      expect(result.error).to eq(I18n.t("payroll.deduction_waiver.errors.not_waivable"))
    end

    %w[obligation_deduction insurance_deduction].each do |excluded_type|
      it "rejects #{excluded_type} — deliberately excluded until explicitly supported" do
        li = create(:payroll_line_item, payroll_entry: entry, item_type: excluded_type,
                    amount: -50.0, review_status: "approved")
        result = described_class.call(line_item: li, action: "waive", actor: manager, reason: "x")
        expect(result.success?).to be false
        expect(result.error).to eq(I18n.t("payroll.deduction_waiver.errors.not_waivable"))
      end
    end

    it "is forbidden without the manage_payroll_deduction_waivers permission" do
      other = create(:user, business: business)
      result = described_class.call(line_item: deduction, action: "waive", actor: other, reason: "x")
      expect(result.success?).to be false
      expect(result.error).to eq(I18n.t("payroll.deduction_waiver.errors.permission"))
    end

    it "is blocked on a locked (finalized) period" do
      period.update!(status: :finalized)
      result = described_class.call(line_item: deduction, action: "waive", actor: manager, reason: "x")
      expect(result.success?).to be false
      expect(result.error).to eq(I18n.t("payroll.deduction_waiver.errors.locked"))
    end
  end

  describe "restore" do
    before { described_class.call(line_item: deduction, action: "waive", actor: manager, reason: "x") }

    it "re-applies the deduction and clears waiver metadata" do
      result = described_class.call(line_item: deduction, action: "restore", actor: manager)

      expect(result.success?).to be true
      deduction.reload
      expect(deduction.deduction_waived?).to be false
      expect(deduction.deduction_waiver_reason).to be_nil
      expect(deduction.deduction_waived_by).to be_nil
      expect(deduction.deduction_waived_at).to be_nil

      entry.reload
      expect(entry.total_deductions).to eq(100.0)
      expect(entry.net_salary).to eq(4_900.0)
    end

    it "rejects restoring a deduction that is not waived" do
      described_class.call(line_item: deduction, action: "restore", actor: manager)
      result = described_class.call(line_item: deduction, action: "restore", actor: manager)
      expect(result.success?).to be false
      expect(result.error).to eq(I18n.t("payroll.deduction_waiver.errors.not_waived"))
    end
  end

  describe "audit logging" do
    it "writes a deduction_waived audit log with the required fields" do
      expect {
        described_class.call(line_item: deduction, action: "waive", actor: manager, reason: "Goodwill")
      }.to change { PayrollAuditLog.where(action_type: "deduction_waived").count }.by(1)

      log = PayrollAuditLog.where(action_type: "deduction_waived").last
      expect(log.payroll_period).to eq(period)
      expect(log.actor).to eq(manager)

      meta = log.metadata_hash
      expect(meta["payroll_period_id"]).to eq(period.id)
      expect(meta["payroll_entry_id"]).to eq(entry.id)
      expect(meta["deduction_id"]).to eq(deduction.id)
      expect(meta["employee_id"]).to eq(employee.id)
      expect(meta["old_state"]).to eq("active")
      expect(meta["new_state"]).to eq("waived")
      expect(meta["reason"]).to eq("Goodwill")
      expect(meta["actor_id"]).to eq(manager.id)
      expect(meta["timestamp"]).to be_present
    end

    it "writes a deduction_restored audit log on restore" do
      described_class.call(line_item: deduction, action: "waive", actor: manager, reason: "x")

      expect {
        described_class.call(line_item: deduction, action: "restore", actor: manager)
      }.to change { PayrollAuditLog.where(action_type: "deduction_restored").count }.by(1)

      log = PayrollAuditLog.where(action_type: "deduction_restored").last
      meta = log.metadata_hash
      expect(meta["old_state"]).to eq("waived")
      expect(meta["new_state"]).to eq("active")
      expect(meta["deduction_id"]).to eq(deduction.id)
    end
  end
end
