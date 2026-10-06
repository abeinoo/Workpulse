require "rails_helper"

# FS-D1 (found in Milestone 2 — Finance & Sales Expenses M0): after
# finalize → reopen → payroll change → re-finalize, the Social Insurance
# Expense kept the amount from the first finalization (the generator's
# idempotency guard skipped because the old expense was still active).
# Reopening a finalized period now voids the active insurance Expense —
# voided_at / voided_by / void_reason, status "cancelled" so Finance reports
# (which count status "approved") exclude it — and re-finalizing creates a new
# Expense from the latest payroll values.
RSpec.describe "Payroll insurance expense after reopen (FS-D1)" do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }
  let(:employee_a) { employee_at(branch_a) }
  let(:period) do
    create(:payroll_period, business: business, period_year: 2026, period_month: 6, status: "branch_review_completed")
  end
  let!(:entry_a) { insured_entry(employee_a, 100) }

  def employee_at(branch)
    create(:user, business: business).tap do |user|
      create(:shift_assignment, user: user, branch: branch, shift: shift, effective_from: Date.new(2026, 1, 1))
    end
  end

  def insured_entry(user, amount)
    create(:payroll_entry, payroll_period: period, user: user, insured: true, employer_insurance_amount: amount)
  end

  def finalize! = expect(Payroll::Approver.advance(period: period.reload, by: owner)).to be_success
  def reopen!   = expect(Payroll::Reopener.call(period: period.reload, by: owner, reason: "Correct insurance")).to be_success

  def insurance_expenses = Expense.where(source_payroll_period: period)
  def active_expenses    = insurance_expenses.where(voided_at: nil)

  it "creates the expense from the first finalization" do
    finalize!

    expect(active_expenses.sole).to have_attributes(amount: 100, status: "approved", branch_id: branch_a.id)
  end

  it "voids the expense on reopen, keeping it as history" do
    finalize!
    expense_a = insurance_expenses.sole

    reopen!

    expect(expense_a.reload).to have_attributes(
      status: "cancelled", voided_by_id: owner.id,
      void_reason: I18n.t("payroll.insurance_expense_void_reason", reason: "Correct insurance")
    )
    expect(expense_a.voided_at).to be_present
    expect(expense_a.amount).to eq(100)
    expect(active_expenses).to be_empty
    expect(AuditLog.where(auditable: expense_a, action: "insurance_expense_voided")).to exist
  end

  it "re-finalizes with the latest payroll values: only the new expense is active" do
    finalize!
    expense_a = insurance_expenses.sole
    reopen!
    entry_a.update_columns(employer_insurance_amount: 300)

    finalize!

    expense_b = active_expenses.sole
    expect(expense_b).not_to eq(expense_a)
    expect(expense_b).to have_attributes(amount: 300, status: "approved")
    expect(expense_a.reload).to have_attributes(amount: 100, status: "cancelled")
    expect(insurance_expenses.count).to eq(2)
    expect(Expense.where(business: business, status: "approved").sum(:amount)).to eq(300)
  end

  it "recalculates the branch split from the new payroll state" do
    finalize!
    expect(insurance_expenses.sole.branch_id).to eq(branch_a.id)
    reopen!
    insured_entry(employee_at(branch_b), 300)

    finalize!

    expense_b = active_expenses.sole
    expect(expense_b).to have_attributes(amount: 400, branch_id: nil, distribution_method: "percentage")
    expect(expense_b.expense_allocations.map { |a| [ a.branch_id, a.allocated_amount ] })
      .to contain_exactly([ branch_a.id, 100 ], [ branch_b.id, 300 ])
  end

  it "keeps repeated generation idempotent after a re-finalization" do
    finalize!
    reopen!
    finalize!

    cost = Payroll::EmployerInsuranceCost.for(period)
    expect { Finance::PayrollInsuranceExpense.record(period: period, actor: owner, total: cost.total, by_branch: cost.by_branch) }
      .not_to change(Expense, :count)
    expect(active_expenses.count).to eq(1)
  end

  it "leaves no active expense when the re-finalized employer total is zero" do
    finalize!
    reopen!
    entry_a.update_columns(employer_insurance_amount: 0)

    finalize!

    expect(active_expenses).to be_empty
    expect(insurance_expenses.sole).to have_attributes(status: "cancelled")
  end

  it "rolls the re-finalization back when expense creation fails" do
    finalize!
    reopen!
    allow(Finance::PayrollInsuranceExpense).to receive(:record).and_raise(ActiveRecord::RecordInvalid.new(Expense.new))

    result = Payroll::Approver.advance(period: period.reload, by: owner)

    expect(result).not_to be_success
    expect(period.reload.status).to eq("branch_review_completed")
    expect(active_expenses).to be_empty
  end

  it "rolls the reopen back when the void fails (the expense stays active)" do
    finalize!
    allow(Finance::PayrollInsuranceExpense).to receive(:void_for).and_raise(ActiveRecord::RecordInvalid.new(Expense.new))

    result = Payroll::Reopener.call(period: period.reload, by: owner, reason: "Correct insurance")

    expect(result).not_to be_success
    expect(period.reload.status).to eq("finalized")
    expect(active_expenses.sole.status).to eq("approved")
  end

  it "does not void the expense when a paid period is reopened back to finalized" do
    finalize!
    period.update_columns(status: "paid")

    reopen!

    expect(period.reload.status).to eq("finalized")
    expect(active_expenses.sole.status).to eq("approved")
  end
end
