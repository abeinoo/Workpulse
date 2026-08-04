require "rails_helper"

# Focused on attendance-penalty waiver preservation across regeneration. The
# waiver lives on deduction_waived (the same unified mechanism every waivable
# deduction type uses — see Payroll::DeductionWaiverPersistence) and is matched
# back to the rebuilt line item by the (user_id, waiver_identity) pair, where
# waiver_identity is [item_type, source AttendanceRecord id] — stable across
# a rebuild since the source record itself is never modified.
RSpec.describe Payroll::Regenerator do
  let(:business) { create(:business) }
  let(:period)   { create(:payroll_period, business: business, status: :draft) }
  let(:employee) { create(:user, business: business) }
  let(:admin)    { create(:user, :accountant, business: business) }
  let(:attendance_record_id) { 9191 }

  before do
    entry = create(:payroll_entry, payroll_period: period, user: employee,
                   base_salary: 5_000.0, total_deductions: 100.0, net_salary: 4_900.0)
    penalty = create(:payroll_line_item, item_type: "late_penalty", payroll_entry: entry,
                     amount: -100.0, review_status: "approved",
                     source_id: attendance_record_id, source_type: "AttendanceRecord")
    Payroll::DeductionWaiver.call(line_item: penalty, action: "waive",
                                  actor: admin, reason: "Traffic accident, excused")

    allow(Payroll::SnapshotService).to receive(:call)
    # Simulate regeneration: destroy and rebuild the entry + its late_penalty item
    # with the SAME source attendance record id (the source record is never modified).
    allow(Payroll::PeriodGenerator).to receive(:call) do
      period.payroll_entries.destroy_all
      rebuilt = create(:payroll_entry, payroll_period: period, user: employee,
                       base_salary: 5_000.0, total_deductions: 100.0, net_salary: 4_900.0)
      create(:payroll_line_item, item_type: "late_penalty", payroll_entry: rebuilt,
             amount: -100.0, review_status: "approved",
             source_id: attendance_record_id, source_type: "AttendanceRecord")
      period
    end
  end

  it "preserves the waiver across regeneration so net salary stays raised" do
    result = described_class.call(period: period, regenerated_by: admin)
    expect(result.success?).to be true

    entry   = period.payroll_entries.find_by(user: employee)
    penalty = entry.payroll_line_items.find_by(item_type: "late_penalty")

    expect(penalty.deduction_waived?).to be true
    expect(penalty.deduction_waiver_reason).to eq("Traffic accident, excused")
    expect(penalty.deduction_waived_by).to eq(admin)
    expect(entry.total_deductions).to eq(0.0)
    expect(entry.net_salary).to eq(5_000.0)
  end
end
