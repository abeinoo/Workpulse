require "rails_helper"

# The employer insurance of floating employees (no home branch) at payroll
# finalization: attributed to no branch — its own unallocated business-level
# Expense — while the other employees' insurance is attributed to their branches
# exactly as before. Never the first-branch fallback.
RSpec.describe "Unallocated employer insurance" do
  let(:business)     { create(:business) }
  let!(:first_branch) { create(:branch, business: business) } # the fallback branch: lowest id
  let(:branch_b)     { create(:branch, business: business) }
  let(:shift)        { create(:shift, :hour_based, business: business) }
  let(:owner)        { create(:user, business: business).tap { |u| business.update!(owner: u) } }
  let(:period)       { create(:payroll_period, business: business, period_year: 2026, period_month: 10, status: "branch_review_completed") }

  let(:regular)  { create(:user, business: business) }
  let(:floating) { create(:user, business: business) }

  before do
    create(:shift_assignment, user: regular, branch: branch_b, shift: shift, effective_from: Date.new(2026, 1, 1))
    create(:shift_assignment, :floating, user: floating, shift: shift, effective_from: Date.new(2026, 1, 1))
    create(:payroll_entry, payroll_period: period, user: regular, insured: true, employer_insurance_amount: 100)
    create(:payroll_entry, payroll_period: period, user: floating, insured: true, employer_insurance_amount: 40)
  end

  def active_expenses = Expense.where(source_payroll_period: period, voided_at: nil)
  # Floating employees need a current central review before finalization: open
  # it (sync) and approve it as a business-level reviewer would, when needed.
  def finalize
    central = Payroll::CentralReview.new(period.reload)
    unless central.current?
      central.sync!(actor: owner)
      Payroll::BranchReviewCompleter.call(period: period.reload, branch: nil, reviewer: owner)
    end
    Payroll::Approver.advance(period: period.reload, by: owner)
  end

  it "splits the payload: total, the branch part and the unallocated part" do
    cost = Payroll::EmployerInsuranceCost.for(period)

    expect(cost.total).to eq(140)
    expect(cost.by_branch).to eq(branch_b.id => 100)
    expect(cost.unallocated).to eq(40)
  end

  it "records the branch part on its branch and the floating part unallocated, never on the first branch" do
    expect(finalize).to be_success

    expect(active_expenses.count).to eq(2)
    expect(active_expenses.find_by!(unallocated: false)).to have_attributes(branch_id: branch_b.id, amount: 100)
    expect(active_expenses.find_by!(unallocated: true)).to have_attributes(branch_id: nil, is_shared: false, amount: 40)
    expect(active_expenses.where(branch_id: first_branch.id)).to be_empty
    expect(ExpenseAllocation.where(expense_id: active_expenses.select(:id))).to be_empty
    expect(active_expenses.sum(:amount)).to eq(140)
  end

  it "is idempotent, voids both on reopen and records both again on refinalization" do
    finalize
    expect { Finance::PayrollInsuranceExpense.record(period: period, actor: owner, total: 140, by_branch: { branch_b.id => 100 }, unallocated: 40) }
      .not_to change(Expense, :count)

    expect(Payroll::Reopener.call(period: period.reload, by: owner, reason: "Correct")).to be_success
    expect(active_expenses).to be_empty
    expect(Expense.where(source_payroll_period: period, status: "cancelled").count).to eq(2)

    expect(finalize).to be_success
    expect(active_expenses.pluck(:unallocated, :amount)).to contain_exactly([ false, 100 ], [ true, 40 ])
  end

  it "records only the unallocated expense when every insured employee is floating" do
    PayrollEntry.find_by!(user: regular).update_columns(insured: false, employer_insurance_amount: 0)

    finalize

    expect(active_expenses.sole).to have_attributes(unallocated: true, branch_id: nil, amount: 40)
  end

  it "keeps the existing single expense when no employee is floating" do
    PayrollEntry.find_by!(user: floating).update_columns(insured: false, employer_insurance_amount: 0)

    finalize

    expect(active_expenses.sole).to have_attributes(unallocated: false, branch_id: branch_b.id, amount: 100)
  end

  it "keeps the first-branch fallback for an employee with no assignment at all (not floating)" do
    ShiftAssignment.where(user: regular).delete_all

    finalize

    expect(active_expenses.find_by!(unallocated: false)).to have_attributes(branch_id: first_branch.id, amount: 100)
  end

  it "attributes an employee who switched to floating during the period by the latest assignment" do
    ShiftAssignment.where(user: floating).delete_all
    create(:shift_assignment, user: floating, branch: branch_b, shift: shift,
                              effective_from: Date.new(2026, 1, 1), effective_to: Date.new(2026, 10, 14))
    create(:shift_assignment, :floating, user: floating, shift: shift, effective_from: Date.new(2026, 10, 15))

    expect(Payroll::EmployerInsuranceCost.for(period).unallocated).to eq(40)
  end
end
