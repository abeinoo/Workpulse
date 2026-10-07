require "rails_helper"

# Characterization (Pilot 8 — Workforce Employee Insurance Profile, M1) —
# CURRENT behaviour of the Attendance & Payroll READ of the Workforce insurance
# profile: Payroll::EntryCalculator snapshots it onto the PayrollEntry
# (insured, employee / employer amounts, insurance number) and adds one
# insurance_deduction line item for the employee contribution.
#
# Already pinned in spec/services/payroll/entry_calculator_spec.rb ("insurance
# snapshot freeze …"): the live snapshot before finalization, re-reading it on
# recalculation, and freezing it once the period was ever finalized. This file
# adds the coverage window, the not-insured / no-profile cases, the number, the
# line item and what the employer amount does (and does not) affect.
RSpec.describe "Characterization: payroll insurance snapshot (AP reads the WF profile)" do
  around { |ex| travel_to(Time.zone.local(2026, 7, 15, 12, 0, 0)) { ex.run } }

  let(:business) { create(:business, working_days_per_month: 22) }
  let(:user)     { create(:user, business: business) }
  let(:period) do # June 2026
    create(:payroll_period, business: business, period_year: 2026, period_month: 6, working_days: 22)
  end

  before { create(:salary_profile, :monthly, user: user, base_amount: 8_800.0, effective_from: Date.new(2026, 1, 1)) }

  def profile(**attrs)
    create(:employee_insurance_profile, { user: user, business: business, employee_contribution_amount: 450.0,
                                          employer_contribution_amount: 1_250.0, insurance_number: "INS-9",
                                          insurance_start_date: Date.new(2026, 1, 1) }.merge(attrs))
  end

  def entry = Payroll::EntryCalculator.call(period: period, user: user, business: business)

  def insurance_items(payroll_entry) = payroll_entry.payroll_line_items.where(item_type: "insurance_deduction")

  it "insured and covering the period: snapshots insured, both amounts and the number" do
    profile
    expect(entry).to have_attributes(insured: true, employee_insurance_amount: 450.0, employer_insurance_amount: 1_250.0,
                                     insurance_number: "INS-9")
  end

  it "adds one insurance_deduction line item of minus the employee contribution, sourced from the profile" do
    insurance = profile
    items = insurance_items(entry)

    expect(items.size).to eq(1)
    expect(items.first.amount).to eq(-450.0)
    expect([ items.first.source_type, items.first.source_id ]).to eq([ "EmployeeInsuranceProfile", insurance.id ])
  end

  it "only the employee contribution reduces net salary; the employer amount is snapshotted, not deducted" do
    uninsured_net = entry.net_salary
    PayrollEntry.where(user: user).destroy_all
    profile

    expect(entry.net_salary).to eq(uninsured_net - 450.0)
  end

  {
    "no profile"                         => nil,
    "a profile that is not insured"      => { insured: false },
    "coverage starting after the period" => { insurance_start_date: Date.new(2026, 7, 1) },
    "coverage ended before the period"   => { insurance_start_date: Date.new(2026, 1, 1), insurance_end_date: Date.new(2026, 5, 31) }
  }.each do |label, attrs|
    it "#{label}: not insured, zero amounts, no number, no line item" do
      profile(**attrs) if attrs

      result = entry
      expect(result).to have_attributes(insured: false, employee_insurance_amount: 0, employer_insurance_amount: 0,
                                        insurance_number: nil)
      expect(insurance_items(result)).to be_empty
    end
  end

  it "coverage overlapping only part of the period counts as the whole period (full amounts, no proration)" do
    profile(insurance_start_date: Date.new(2026, 6, 20))
    expect(entry).to have_attributes(insured: true, employee_insurance_amount: 450.0)

    PayrollEntry.where(user: user).destroy_all
    EmployeeInsuranceProfile.where(user: user).update_all(insurance_start_date: Date.new(2026, 1, 1),
                                                          insurance_end_date: Date.new(2026, 6, 1))
    expect(entry).to have_attributes(insured: true, employee_insurance_amount: 450.0)
  end

  it "reads the profile through User#employee_insurance_profile and never writes it" do
    insurance = profile
    before = insurance.reload.attributes

    entry
    expect(insurance.reload.attributes).to eq(before)
  end
end
