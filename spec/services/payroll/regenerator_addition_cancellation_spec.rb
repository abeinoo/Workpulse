require "rails_helper"

# Focused on addition/bonus cancellation preservation across regeneration. The
# cancellation lives at the payroll layer and is matched back to the rebuilt
# line item by the (user_id, source adjustment id) pair, which is stable
# across a rebuild. Mirrors regenerator_deduction_waiver_spec.rb.
RSpec.describe Payroll::Regenerator do
  let(:business) { create(:business) }
  let(:period)   { create(:payroll_period, business: business, status: :draft) }
  let(:employee) { create(:user, business: business) }
  let(:admin)    { create(:user, :accountant, business: business) }
  let(:adjustment_id) { 4242 }

  before do
    entry = create(:payroll_entry, payroll_period: period, user: employee,
                   base_salary: 5_000.0, total_bonuses: 300.0, net_salary: 5_300.0)
    bonus = create(:payroll_line_item, :commission, payroll_entry: entry,
                   amount: 300.0, source_id: adjustment_id)
    Payroll::AdditionCanceller.call(line_item: bonus, actor: admin, reason: "Entered in error")

    allow(Payroll::SnapshotService).to receive(:call)
    # Simulate regeneration: destroy and rebuild the entry + its bonus with the
    # SAME source adjustment id (the source record is never modified).
    allow(Payroll::PeriodGenerator).to receive(:call) do
      period.payroll_entries.destroy_all
      rebuilt = create(:payroll_entry, payroll_period: period, user: employee,
                       base_salary: 5_000.0, total_bonuses: 300.0, net_salary: 5_300.0)
      create(:payroll_line_item, :commission, payroll_entry: rebuilt,
             amount: 300.0, source_id: adjustment_id)
      period
    end
  end

  it "preserves the cancellation across regeneration so net salary stays lowered" do
    result = described_class.call(period: period, regenerated_by: admin)
    expect(result.success?).to be true

    entry = period.payroll_entries.find_by(user: employee)
    bonus = entry.payroll_line_items.find_by(item_type: "commission")

    expect(bonus.addition_cancelled?).to be true
    expect(bonus.addition_cancellation_reason).to eq("Entered in error")
    expect(entry.total_bonuses).to eq(0.0)
    expect(entry.net_salary).to eq(5_000.0)
  end
end

# Same preservation guarantee for a system-generated overtime line item — there
# is no type allowlist, so overtime must be preserved across regeneration
# exactly like a manager-submitted bonus.
RSpec.describe "Payroll::Regenerator — overtime cancellation" do
  let(:business) { create(:business) }
  let(:period)   { create(:payroll_period, business: business, status: :draft) }
  let(:employee) { create(:user, business: business) }
  let(:admin)    { create(:user, :accountant, business: business) }
  let(:attendance_record_id) { 9191 }

  before do
    entry = create(:payroll_entry, payroll_period: period, user: employee,
                   base_salary: 5_000.0, total_overtime: 75.0, calculated_overtime_pay: 75.0,
                   net_salary: 5_075.0)
    overtime = create(:payroll_line_item, :overtime, payroll_entry: entry,
                      amount: 75.0, source_type: "AttendanceRecord", source_id: attendance_record_id)
    Payroll::AdditionCanceller.call(line_item: overtime, actor: admin, reason: "Not authorised")

    allow(Payroll::SnapshotService).to receive(:call)
    allow(Payroll::PeriodGenerator).to receive(:call) do
      period.payroll_entries.destroy_all
      rebuilt = create(:payroll_entry, payroll_period: period, user: employee,
                       base_salary: 5_000.0, total_overtime: 75.0, calculated_overtime_pay: 75.0,
                       net_salary: 5_075.0)
      create(:payroll_line_item, :overtime, payroll_entry: rebuilt,
             amount: 75.0, source_type: "AttendanceRecord", source_id: attendance_record_id)
      period
    end
  end

  it "preserves the cancellation across regeneration so net salary stays lowered" do
    result = Payroll::Regenerator.call(period: period, regenerated_by: admin)
    expect(result.success?).to be true

    entry    = period.payroll_entries.find_by(user: employee)
    overtime = entry.payroll_line_items.find_by(item_type: "overtime")

    expect(overtime.addition_cancelled?).to be true
    expect(overtime.addition_cancellation_reason).to eq("Not authorised")
    expect(entry.total_overtime).to eq(0.0)
    expect(entry.net_salary).to eq(5_000.0)
  end

  # "المحتسب" (calculated_overtime_pay) and "المعتمد" (payable_overtime_pay) must
  # both be recomputed by the regenerator's post-reapply recalculate_totals!,
  # not just total_overtime.
  it "recalculates المحتسب and المعتمد to zero after regeneration" do
    result = Payroll::Regenerator.call(period: period, regenerated_by: admin)
    expect(result.success?).to be true

    entry = period.payroll_entries.find_by(user: employee)
    expect(entry.calculated_overtime_pay).to eq(0.0)
    expect(entry.payable_overtime_pay).to eq(0.0)
  end
end

# Multiple overtime items cancelled on the same entry — both must stay
# excluded from the totals across a regeneration, not just the first one.
RSpec.describe "Payroll::Regenerator — multiple overtime cancellations" do
  let(:business) { create(:business) }
  let(:period)   { create(:payroll_period, business: business, status: :draft) }
  let(:employee) { create(:user, business: business) }
  let(:admin)    { create(:user, :accountant, business: business) }
  let(:record_id_1) { 8801 }
  let(:record_id_2) { 8802 }

  before do
    entry = create(:payroll_entry, payroll_period: period, user: employee,
                   base_salary: 5_000.0, total_overtime: 150.0, calculated_overtime_pay: 150.0,
                   net_salary: 5_150.0)
    ot1 = create(:payroll_line_item, :overtime, payroll_entry: entry,
                amount: 75.0, source_type: "AttendanceRecord", source_id: record_id_1)
    ot2 = create(:payroll_line_item, :overtime, payroll_entry: entry,
                amount: 75.0, source_type: "AttendanceRecord", source_id: record_id_2)
    Payroll::AdditionCanceller.call(line_item: ot1, actor: admin, reason: "Not authorised")
    Payroll::AdditionCanceller.call(line_item: ot2, actor: admin, reason: "Not authorised")

    allow(Payroll::SnapshotService).to receive(:call)
    allow(Payroll::PeriodGenerator).to receive(:call) do
      period.payroll_entries.destroy_all
      rebuilt = create(:payroll_entry, payroll_period: period, user: employee,
                       base_salary: 5_000.0, total_overtime: 150.0, calculated_overtime_pay: 150.0,
                       net_salary: 5_150.0)
      create(:payroll_line_item, :overtime, payroll_entry: rebuilt,
             amount: 75.0, source_type: "AttendanceRecord", source_id: record_id_1)
      create(:payroll_line_item, :overtime, payroll_entry: rebuilt,
             amount: 75.0, source_type: "AttendanceRecord", source_id: record_id_2)
      period
    end
  end

  it "preserves both cancellations across regeneration" do
    result = Payroll::Regenerator.call(period: period, regenerated_by: admin)
    expect(result.success?).to be true

    entry = period.payroll_entries.find_by(user: employee)
    expect(entry.payroll_line_items.where(item_type: "overtime", addition_cancelled: true).count).to eq(2)
    expect(entry.total_overtime).to eq(0.0)
    expect(entry.calculated_overtime_pay).to eq(0.0)
    expect(entry.payable_overtime_pay).to eq(0.0)
    expect(entry.net_salary).to eq(5_000.0)
  end
end
