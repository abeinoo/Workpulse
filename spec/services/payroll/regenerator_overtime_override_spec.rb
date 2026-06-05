require "rails_helper"

# Focused on overtime-override preservation across regeneration. PeriodGenerator
# is stubbed to simulate the destroy-and-rebuild with changed calculated overtime.
RSpec.describe Payroll::Regenerator do
  let(:business) { create(:business) }
  let(:period)   { create(:payroll_period, business: business, status: :draft) }
  let(:employee) { create(:user, business: business) }
  let(:admin)    { create(:user, :accountant, business: business) }

  before do
    entry = create(:payroll_entry, payroll_period: period, user: employee,
                   total_overtime: 300.0, net_salary: 5_300.0,
                   calculated_overtime_minutes: 240, calculated_overtime_pay: 300.0)
    create(:payroll_line_item, :overtime, payroll_entry: entry, amount: 300.0)
    Payroll::OvertimeOverrider.call(entry: entry, mode: "amount", value: 100, reason: "cap", actor: admin)

    allow(Payroll::SnapshotService).to receive(:call)
    # Simulate regeneration: rebuild the entry with reduced calculated overtime (300 → 200).
    allow(Payroll::PeriodGenerator).to receive(:call) do
      period.payroll_entries.destroy_all
      rebuilt = create(:payroll_entry, payroll_period: period, user: employee,
                       total_overtime: 200.0, net_salary: 5_200.0,
                       calculated_overtime_minutes: 120, calculated_overtime_pay: 200.0)
      create(:payroll_line_item, :overtime, payroll_entry: rebuilt, amount: 200.0)
      period
    end
  end

  it "preserves the override, clamps to new calculated, and flags it stale" do
    result = described_class.call(period: period, regenerated_by: admin)
    expect(result.success?).to be true

    entry = period.payroll_entries.find_by(user: employee)
    expect(entry.overtime_overridden?).to be true
    expect(entry.overtime_override_mode).to eq("amount")
    # Approved amount 100 still <= new calculated 200, so it is preserved.
    expect(entry.total_overtime).to eq(100.0)
    expect(entry.overtime_override_reason).to eq("cap")
    # Calculated overtime changed (300 → 200), so the override is flagged for re-review.
    expect(entry.overtime_override_stale?).to be true
  end
end
