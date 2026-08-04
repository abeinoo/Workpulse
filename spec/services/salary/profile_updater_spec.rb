require "rails_helper"

RSpec.describe Salary::ProfileUpdater do
  let(:business) { create(:business) }
  let(:employee) { create(:user, business: business) }
  let(:actor)    { create(:user, :accountant, business: business) }

  let!(:existing_profile) do
    create(:salary_profile, :monthly, user: employee, base_amount: 5_000.0,
           effective_from: 1.year.ago.to_date)
  end

  let(:period) do
    create(:payroll_period, business: business, status: :under_review,
           period_year: Date.current.year, period_month: Date.current.month)
  end

  def run(base_amount: 6_000.0)
    described_class.call(
      user:   employee,
      actor:  actor,
      params: { salary_type: "monthly", base_amount: base_amount,
                currency: "SAR", effective_from: 1.year.ago.to_date }
    )
  end

  it "deactivates the previous profile and creates a new active one" do
    result = run
    expect(result.success?).to be true
    expect(existing_profile.reload.active?).to be false
    expect(result.profile.active?).to be true
  end

  it "recalculates every currently editable period that has an entry for the user" do
    Payroll::EntryCalculator.call(period: period, user: employee, business: business)
    entry = period.payroll_entries.find_by(user: employee)
    expect(entry.base_salary).to eq(5_000.0)

    run(base_amount: 9_000.0)

    expect(entry.reload.base_salary).to eq(9_000.0)
  end

  it "does not touch entries in locked periods" do
    locked = create(:payroll_period, business: business, status: :finalized,
                    period_year: 1.month.ago.year, period_month: 1.month.ago.month)
    Payroll::EntryCalculator.call(period: locked, user: employee, business: business)
    entry = locked.payroll_entries.find_by(user: employee)

    run(base_amount: 9_000.0)

    expect(entry.reload.base_salary).to eq(5_000.0)
  end

  it "does not fail the profile change if recalculation raises" do
    allow(Payroll::EntryRecalculator).to receive(:recalculate_all_open_periods_for).and_raise("boom")

    result = run
    expect(result.success?).to be true
  end
end
