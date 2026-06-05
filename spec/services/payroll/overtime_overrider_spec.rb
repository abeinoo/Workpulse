require "rails_helper"

RSpec.describe Payroll::OvertimeOverrider do
  let(:business) { create(:business) }
  let(:period)   { create(:payroll_period, business: business, status: :draft) }
  let(:employee) { create(:user, business: business) }
  let(:manager)  { create(:user, :accountant, business: business) }

  # Entry with 4h (240 min) of calculated overtime worth 300, backed by a line item
  # so recalculate_totals! keeps calculated_overtime_pay in sync.
  let(:entry) do
    e = create(:payroll_entry,
               payroll_period: period, user: employee,
               total_overtime: 300.0, net_salary: 5_300.0,
               calculated_overtime_minutes: 240, calculated_overtime_pay: 300.0)
    create(:payroll_line_item, :overtime, payroll_entry: e, amount: 300.0)
    e
  end

  describe "amount mode" do
    it "sets payable overtime to a fixed amount and derives minutes" do
      result = described_class.call(entry: entry, mode: "amount", value: 150, reason: "Partial approval", actor: manager)

      expect(result.success?).to be true
      entry.reload
      expect(entry.total_overtime).to eq(150.0)
      expect(entry.approved_overtime_pay).to eq(150.0)
      expect(entry.approved_overtime_minutes).to eq(120)
      expect(entry.payable_overtime_minutes).to eq(120)
      expect(entry.net_salary).to eq(5_150.0)
      expect(entry.overtime_overridden?).to be true
    end

    it "zeroes overtime (the primary workflow)" do
      described_class.call(entry: entry, mode: "amount", value: 0, reason: "Forgot to check out", actor: manager)

      entry.reload
      expect(entry.total_overtime).to eq(0.0)
      expect(entry.payable_overtime_minutes).to eq(0)
      expect(entry.net_salary).to eq(5_000.0)
      expect(entry.overtime_difference).to eq(300.0)
    end

    it "clamps an amount above the calculated value" do
      described_class.call(entry: entry, mode: "amount", value: 999, reason: "x", actor: manager)
      # Equal to calculated => normalised to no override.
      expect(entry.reload.overtime_overridden?).to be false
      expect(entry.total_overtime).to eq(300.0)
    end
  end

  describe "minutes mode" do
    it "approves N minutes and scales pay pro-rata" do
      described_class.call(entry: entry, mode: "minutes", value: 120, reason: "Half approved", actor: manager)

      entry.reload
      expect(entry.approved_overtime_minutes).to eq(120)
      expect(entry.total_overtime).to eq(150.0)
      expect(entry.net_salary).to eq(5_150.0)
    end
  end

  describe "restore" do
    it "clears an existing override" do
      described_class.call(entry: entry, mode: "amount", value: 100, reason: "reduce", actor: manager)
      described_class.call(entry: entry, mode: "restore", actor: manager)

      entry.reload
      expect(entry.overtime_overridden?).to be false
      expect(entry.total_overtime).to eq(300.0)
      expect(entry.net_salary).to eq(5_300.0)
    end
  end

  describe "validation" do
    it "requires a reason when the value differs from calculated" do
      result = described_class.call(entry: entry, mode: "amount", value: 100, actor: manager)
      expect(result.success?).to be false
      expect(result.error).to be_present
      expect(entry.reload.overtime_overridden?).to be false
    end

    it "rejects actors without the permission" do
      result = described_class.call(entry: entry, mode: "amount", value: 0, reason: "x", actor: employee)
      expect(result.success?).to be false
    end

    it "blocks overrides on a locked period" do
      period.update!(status: :finalized)
      result = described_class.call(entry: entry, mode: "amount", value: 0, reason: "x", actor: manager)
      expect(result.success?).to be false
    end

    it "rejects overriding an entry with no calculated overtime" do
      plain = create(:payroll_entry, payroll_period: period, user: create(:user, business: business))
      result = described_class.call(entry: plain, mode: "amount", value: 0, reason: "x", actor: manager)
      expect(result.success?).to be false
    end
  end

  describe "audit" do
    it "writes an overtime_overridden audit log" do
      expect {
        described_class.call(entry: entry, mode: "amount", value: 0, reason: "False OT", actor: manager)
      }.to change { PayrollAuditLog.where(action_type: "overtime_overridden").count }.by(1)

      log = PayrollAuditLog.where(action_type: "overtime_overridden").last
      meta = log.metadata_hash
      expect(log.actor).to eq(manager)
      expect(meta["employee_id"]).to eq(employee.id)
      expect(meta["old_pay"]).to eq(300.0)
      expect(meta["new_pay"]).to eq(0.0)
      expect(meta["reason"]).to eq("False OT")
    end
  end
end
