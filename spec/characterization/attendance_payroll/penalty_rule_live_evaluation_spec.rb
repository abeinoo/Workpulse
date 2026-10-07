require "rails_helper"

# Characterization (Pilot 4 — Penalty Rules, M1) — CURRENT live evaluation of
# penalty rules (TD-P4-3): rules are read when payroll is calculated, never
# snapshotted, so a rule change reaches an open period at its next
# recalculation and leaves locked (finalized / paid) periods' line items as
# they were. Penalty maths (thresholds, percentage of daily rate) is in
# spec/services/attendance/penalty_calculator_spec.rb and
# spec/services/payroll/entry_calculator_spec.rb.
RSpec.describe "Characterization: penalty rules are evaluated live" do
  around { |example| travel_to(Time.zone.local(2026, 7, 15, 12)) { example.run } }

  let(:business) { create(:business, working_days_per_month: 22) }
  let(:branch)   { create(:branch, business: business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:shift) do
    create(:shift, :fixed_time, business: business, start_time: Time.zone.parse("09:00"), end_time: Time.zone.parse("17:00"))
  end
  let(:assignment) { create(:shift_assignment, user: employee, branch: branch, shift: shift, effective_from: 3.months.ago.to_date) }
  let(:period)     { create(:payroll_period, business: business, period_year: 2026, period_month: 6, working_days: 22) }

  # daily rate = 8,800 / 22 = 400
  let!(:rule) do
    create(:penalty_rule, shift: shift, rule_type: "late_arrival", deduction_type: "percentage_of_daily",
                          threshold_minutes: 15, deduction_value: 25)
  end

  before do
    create(:salary_profile, :monthly, user: employee, base_amount: 8_800, effective_from: 6.months.ago.to_date)
    day = Date.new(2026, 6, 10)
    @record = create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment,
                                         date: day, work_date: day, worked_minutes: 440, late_minutes: 40, status: "late",
                                         check_in_at: Time.zone.local(2026, 6, 10, 9, 40),
                                         check_out_at: Time.zone.local(2026, 6, 10, 17, 0))
  end

  def calculate         = Payroll::EntryCalculator.call(period: period, user: employee, business: business)
  def recalculate       = Payroll::EntryRecalculator.call(user: employee, period: period.reload, triggered_by: owner)
  def late_penalties    = PayrollLineItem.joins(:payroll_entry)
                                         .where(payroll_entries: { payroll_period_id: period.id }, item_type: "late_penalty")
  def late_penalty_amounts = late_penalties.pluck(:amount)

  it "uses the rule's value at calculation time" do
    calculate
    expect(late_penalty_amounts).to eq([ -100 ])
  end

  it "applies an edited rule to an open period at its next recalculation" do
    calculate
    rule.update!(deduction_value: 50)

    expect(late_penalty_amounts).to eq([ -100 ]) # nothing changes until recalculation
    expect(recalculate).to be_ok
    expect(late_penalty_amounts).to eq([ -200 ])
  end

  it "drops the penalty from an open period at its next recalculation once the rule is deleted" do
    calculate
    rule.destroy!

    recalculate
    expect(late_penalties).to be_empty
  end

  it "leaves a finalized period's penalty line items unchanged after a rule edit or delete" do
    calculate
    item = late_penalties.sole
    period.update_column(:status, "finalized")

    rule.update!(deduction_value: 50)
    expect(recalculate).to have_attributes(ok: true, entry: nil) # locked periods are skipped
    rule.destroy!
    recalculate

    expect(late_penalties.sole).to eq(item)
    expect(item.reload.amount).to eq(-100)
  end

  it "does not touch stored attendance outcomes when a rule changes (no callbacks)" do
    expect { rule.update!(threshold_minutes: 60) }
      .not_to(change { @record.reload.attributes.slice("status", "late_minutes", "updated_at") })
  end
end
