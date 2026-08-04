require "rails_helper"

RSpec.describe Employee::InsuranceProfileUpdater do
  let(:business) { create(:business) }
  let(:employee) { create(:user, business: business) }
  let(:actor)    { create(:user, :accountant, business: business) }

  let!(:salary_profile) do
    create(:salary_profile, :monthly, user: employee, base_amount: 5_000.0,
           effective_from: 1.year.ago.to_date)
  end

  let(:period) do
    create(:payroll_period, business: business, status: :under_review,
           period_year: Date.current.year, period_month: Date.current.month)
  end

  def run(insured: true, employee_contribution_amount: 500.0)
    described_class.call(
      user_id: employee.id,
      actor:   actor,
      attrs:   {
        insured: insured,
        employee_contribution_amount: employee_contribution_amount,
        employer_contribution_amount: 1_000.0,
        insurance_start_date: 1.year.ago.to_date
      }
    )
  end

  it "creates the insurance profile" do
    result = run
    expect(result.ok?).to be true
    expect(employee.reload.employee_insurance_profile).to be_present
  end

  it "recalculates every currently editable period that has an entry for the user" do
    Payroll::EntryCalculator.call(period: period, user: employee, business: business)
    entry = period.payroll_entries.find_by(user: employee)
    expect(entry.insured?).to be false

    run(insured: true, employee_contribution_amount: 500.0)

    expect(entry.reload.insured?).to be true
    expect(entry.employee_insurance_amount).to eq(500.0)
  end

  it "does not touch entries in locked periods" do
    locked = create(:payroll_period, business: business, status: :finalized,
                    period_year: 1.month.ago.year, period_month: 1.month.ago.month)
    Payroll::EntryCalculator.call(period: locked, user: employee, business: business)
    entry = locked.payroll_entries.find_by(user: employee)

    run(insured: true, employee_contribution_amount: 500.0)

    expect(entry.reload.insured?).to be false
  end

  it "does not fail the profile change if recalculation raises" do
    allow(Payroll::EntryRecalculator).to receive(:recalculate_all_open_periods_for).and_raise("boom")

    result = run
    expect(result.ok?).to be true
  end
end
