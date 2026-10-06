require "rails_helper"

# Milestone 2 — Finance & Sales Expenses, M4: the employer insurance cost of a
# period, computed by Attendance & Payroll from its own entries (and the
# Workforce ShiftAssignment read) and passed to Finance through
# Payroll::FinalizationEffects. Moved unchanged from the former
# Payroll::InsuranceExpenseGenerator.
RSpec.describe Payroll::EmployerInsuranceCost do
  let(:business) { create(:business) }
  let!(:branch_a) { create(:branch, business: business) }
  let!(:branch_b) { create(:branch, business: business) }
  let(:shift) { create(:shift, :fixed_time, business: business) }
  let(:period) { create(:payroll_period, business: business, period_year: 2026, period_month: 6) }

  def employee_at(branch, from: Date.new(2026, 1, 1))
    create(:user, business: business).tap do |user|
      create(:shift_assignment, user: user, branch: branch, shift: shift, effective_from: from) if branch
    end
  end

  def entry(user, amount, insured: true)
    create(:payroll_entry, payroll_period: period, user: user, insured: insured, employer_insurance_amount: amount)
  end

  it "totals insured entries only and attributes each to the employee's branch during the period" do
    entry(employee_at(branch_a), 100)
    entry(employee_at(branch_b), 250)
    entry(employee_at(branch_a), 40)
    entry(employee_at(branch_b), 999, insured: false)

    cost = described_class.for(period)

    expect(cost.total).to eq(390)
    expect(cost.by_branch).to eq(branch_a.id => 140, branch_b.id => 250)
  end

  it "falls back to the business's first branch when the employee has no assignment in the period" do
    entry(employee_at(nil), 70)
    entry(employee_at(branch_b, from: Date.new(2026, 8, 1)), 30)

    expect(described_class.for(period).by_branch).to eq(branch_a.id => 100)
  end

  it "returns a zero total and no branches when nothing is insured" do
    entry(employee_at(branch_a), 100, insured: false)

    cost = described_class.for(period)

    expect(cost.total).to eq(0)
    expect(cost.by_branch).to eq({})
  end

  it "is read-only" do
    entry(employee_at(branch_a), 100)

    expect { described_class.for(period) }.not_to change { [ Expense.count, ExpenseCategory.count, AuditLog.count ] }
  end
end
