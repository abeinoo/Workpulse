require "rails_helper"

RSpec.describe Payroll::BulkOvertimeOverrider do
  let(:business) { create(:business) }
  let(:period)   { create(:payroll_period, business: business, status: :draft) }
  let(:manager)  { create(:user, :accountant, business: business) }

  def entry_with_overtime(minutes: 240, pay: 300.0)
    e = create(:payroll_entry,
               payroll_period: period, user: create(:user, business: business),
               total_overtime: pay, net_salary: 5_000.0 + pay,
               calculated_overtime_minutes: minutes, calculated_overtime_pay: pay)
    create(:payroll_line_item, :overtime, payroll_entry: e, amount: pay)
    e
  end

  describe "zero mode (primary workflow)" do
    it "zeroes overtime for all selected entries" do
      e1 = entry_with_overtime
      e2 = entry_with_overtime

      result = described_class.call(
        period: period, entry_ids: [ e1.id, e2.id ], bulk_mode: "zero",
        reason: "Branch closed early", actor: manager
      )

      expect(result.success?).to be true
      expect(result.applied).to eq(2)
      expect(e1.reload.total_overtime).to eq(0.0)
      expect(e2.reload.total_overtime).to eq(0.0)
    end

    it "skips entries with no calculated overtime" do
      ot    = entry_with_overtime
      plain = create(:payroll_entry, payroll_period: period, user: create(:user, business: business))

      result = described_class.call(
        period: period, entry_ids: [ ot.id, plain.id ], bulk_mode: "zero",
        reason: "x", actor: manager
      )

      expect(result.applied).to eq(1)
      expect(result.skipped).to eq(1)
    end
  end

  describe "fixed_amount mode" do
    it "sets a fixed payable amount on each entry" do
      e1 = entry_with_overtime
      described_class.call(period: period, entry_ids: [ e1.id ], bulk_mode: "fixed_amount",
                           value: 100, reason: "Cap", actor: manager)
      expect(e1.reload.total_overtime).to eq(100.0)
    end
  end

  describe "restore mode" do
    it "clears overrides" do
      e1 = entry_with_overtime
      Payroll::OvertimeOverrider.call(entry: e1, mode: "amount", value: 0, reason: "x", actor: manager)
      described_class.call(period: period, entry_ids: [ e1.id ], bulk_mode: "restore", actor: manager)
      expect(e1.reload.overtime_overridden?).to be false
      expect(e1.total_overtime).to eq(300.0)
    end
  end

  describe "guards" do
    it "fails on a locked period" do
      period.update!(status: :paid)
      result = described_class.call(period: period, entry_ids: [ 1 ], bulk_mode: "zero", reason: "x", actor: manager)
      expect(result.success?).to be false
    end

    it "fails when nothing is selected" do
      result = described_class.call(period: period, entry_ids: [], bulk_mode: "zero", reason: "x", actor: manager)
      expect(result.success?).to be false
    end
  end
end
