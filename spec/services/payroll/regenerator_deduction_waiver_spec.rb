require "rails_helper"

# Focused on manual-deduction waiver preservation across regeneration. The waiver
# lives at the payroll layer and is matched back to the rebuilt line item by the
# (user_id, source adjustment id) pair, which is stable across a rebuild.
RSpec.describe Payroll::Regenerator do
  let(:business) { create(:business) }
  let(:period)   { create(:payroll_period, business: business, status: :draft) }
  let(:employee) { create(:user, business: business) }
  let(:admin)    { create(:user, :accountant, business: business) }
  let(:adjustment_id) { 4242 }

  before do
    entry = create(:payroll_entry, payroll_period: period, user: employee,
                   base_salary: 5_000.0, total_deductions: 100.0, net_salary: 4_900.0)
    deduction = create(:payroll_line_item, :manual_deduction, payroll_entry: entry,
                       amount: -100.0, source_id: adjustment_id)
    Payroll::DeductionWaiver.call(line_item: deduction, action: "waive", actor: admin, reason: "Goodwill")

    allow(Payroll::SnapshotService).to receive(:call)
    # Simulate regeneration: destroy and rebuild the entry + its manual deduction
    # with the SAME source adjustment id (the source record is never modified).
    allow(Payroll::PeriodGenerator).to receive(:call) do
      period.payroll_entries.destroy_all
      rebuilt = create(:payroll_entry, payroll_period: period, user: employee,
                       base_salary: 5_000.0, total_deductions: 100.0, net_salary: 4_900.0)
      create(:payroll_line_item, :manual_deduction, payroll_entry: rebuilt,
             amount: -100.0, source_id: adjustment_id)
      period
    end
  end

  it "preserves the waiver across regeneration so net salary stays raised" do
    result = described_class.call(period: period, regenerated_by: admin)
    expect(result.success?).to be true

    entry     = period.payroll_entries.find_by(user: employee)
    deduction = entry.payroll_line_items.manual_deductions.first

    expect(deduction.deduction_waived?).to be true
    expect(deduction.deduction_waiver_reason).to eq("Goodwill")
    expect(entry.total_deductions).to eq(0.0)
    expect(entry.net_salary).to eq(5_000.0)
  end
end
