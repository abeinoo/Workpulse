require "rails_helper"

# Characterization (Milestone 2 Pilot 2, M1) — CURRENT end-to-end interaction of
# an EmployeeObligation with successive payroll periods (EntryCalculator →
# ObligationDeductor → ObligationDeduction callbacks). Unit rules (installment
# maths, repay!/restore!, covering_period, deductor branches) are in the model
# and service specs; AP-D4/AP-D5 in spec/requests/payroll_obligation_*_spec.rb.
RSpec.describe "Characterization: employee obligation through payroll" do
  around { |example| travel_to(Time.zone.local(2026, 9, 15, 12)) { example.run } }

  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:employee) { create(:user, business: business) }

  before { create(:salary_profile, :monthly, user: employee, base_amount: 8_800, effective_from: 1.year.ago.to_date) }

  def period(month, status: "draft")
    create(:payroll_period, business: business, period_year: 2026, period_month: month, working_days: 22, status: status)
  end

  def calculate(period) = Payroll::EntryCalculator.call(period: period, user: employee, business: business)

  def deducted(period) = PayrollEntry.find_by!(payroll_period: period, user: employee).obligations_deducted

  def obligation(**attributes)
    create(:employee_obligation, user: employee, business: business, created_by: owner,
                                 start_month: 6, start_year: 2026, **attributes)
  end

  it "deducts one installment per period, then the smaller final installment, and completes at zero" do
    loan = obligation(total_amount: 1_200, remaining_amount: 1_200, installment_amount: 500)

    results = [ 6, 7, 8 ].map do |month|
      p = period(month)
      calculate(p)
      p.update_column(:status, "finalized")
      [ deducted(p), loan.reload.remaining_amount, loan.status ]
    end

    expect(results).to eq([ [ 500, 700, "active" ], [ 500, 200, "active" ], [ 200, 0, "completed" ] ])
    expect(loan.obligation_deductions.count).to eq(3)
  end

  it "records each deduction as a snapshot of the balance before and after" do
    loan = obligation(total_amount: 1_000, remaining_amount: 1_000, installment_amount: 400)
    calculate(period(6))

    expect(loan.obligation_deductions.sole).to have_attributes(deducted_amount: 400, remaining_before: 1_000, remaining_after: 600)
  end

  it "does not deduct a completed obligation in later periods" do
    loan = obligation(total_amount: 500, remaining_amount: 500, installment_amount: 500)
    june = period(6)
    calculate(june)
    june.update_column(:status, "finalized")
    expect(loan.reload).to be_completed

    july = period(7)
    calculate(july)

    expect(deducted(july)).to eq(0)
  end

  it "reopens and re-completes a completed obligation when its open period is recalculated" do
    loan  = obligation(total_amount: 500, remaining_amount: 500, installment_amount: 500)
    june  = period(6)
    calculate(june)
    expect(loan.reload).to be_completed

    Payroll::EntryRecalculator.call(user: employee, period: june, triggered_by: owner)

    expect(loan.reload).to have_attributes(status: "completed", remaining_amount: 0)
    expect(loan.obligation_deductions.count).to eq(1)
    expect(deducted(june)).to eq(500)
  end

  it "does not deduct a cancelled, a not-yet-started or a manual (auto_deduct off) obligation" do
    obligation(status: "cancelled")
    obligation(start_month: 12)
    obligation(auto_deduct: false)
    p = period(9)

    calculate(p)

    expect(deducted(p)).to eq(0)
    expect(ObligationDeduction.where(payroll_period: p)).to be_empty
  end

  it "does not deduct the same obligation twice in one period when the entry is recalculated" do
    loan = obligation(total_amount: 3_000, remaining_amount: 3_000, installment_amount: 500)
    p    = period(9)
    calculate(p)

    2.times { Payroll::EntryRecalculator.call(user: employee, period: p, triggered_by: owner) }

    expect(deducted(p)).to eq(500)
    expect(loan.reload.remaining_amount).to eq(2_500)
    expect(loan.obligation_deductions.count).to eq(1)
  end

  it "leaves a finalized period's deduction and snapshot alone on recalculation" do
    loan = obligation(total_amount: 3_000, remaining_amount: 3_000, installment_amount: 500)
    p    = period(9)
    calculate(p)
    p.update_column(:status, "finalized")

    Payroll::EntryRecalculator.call(user: employee, period: p, triggered_by: owner)

    expect(loan.reload.remaining_amount).to eq(2_500)
    expect(loan.obligation_deductions.count).to eq(1)
    expect(loan).to be_payroll_locked
  end
end
