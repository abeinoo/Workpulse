require "rails_helper"

# Characterization (Milestone 2 — Finance & Sales Expenses, M1) — CURRENT shape
# of the system-generated Social Insurance Expense that payroll finalization
# creates (Payroll::Approver → Payroll::InsuranceExpenseGenerator, the AP → FS
# write the M2 contract will route). Reopen/void/re-finalize, split allocation,
# idempotency and rollback are in spec/services/payroll/insurance_expense_refresh_spec.rb
# (FS-D1); category capitalisation in insurance_expense_category_spec.rb (FS-D2).
RSpec.describe "Characterization: payroll insurance expense" do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let!(:first_branch) { create(:branch, business: business) }
  let(:period) do
    create(:payroll_period, business: business, period_year: 2026, period_month: 6, status: "branch_review_completed")
  end

  def insured(user, amount, insured: true)
    create(:payroll_entry, payroll_period: period, user: user, insured: insured, employer_insurance_amount: amount)
  end

  def finalize
    result = Payroll::Approver.advance(period: period, by: owner)
    expect(result).to be_success
    Expense.find_by(source_payroll_period: period)
  end

  it "creates one approved, system-generated, locked expense dated at period end" do
    insured(create(:user, business: business), 100)

    expense = finalize

    expect(expense).to have_attributes(
      status: "approved", amount: 100, expense_date: Date.new(2026, 6, 30),
      created_by_id: owner.id, approved_by_id: owner.id,
      payment_type: "direct", deduct_from_balance: false, payment_source: "not_linked_to_balance",
      reference_number: "EXP-000001"
    )
    expect(expense.approved_at).to be_present
    expect(expense).to be_system_generated
    expect(expense.financial_settlements).to be_empty
    expect(AuditLog.where(auditable: expense, action: "insurance_expense_generated")).to exist
  end

  it "cannot be edited or deleted (system-generated lock)" do
    insured(create(:user, business: business), 100)
    expense = finalize

    expect { expense.update!(amount: 1) }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect { expense.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end

  it "counts only insured entries' employer contributions" do
    insured(create(:user, business: business), 100)
    insured(create(:user, business: business), 900, insured: false)

    expect(finalize.amount).to eq(100)
  end

  it "attributes an employee without a shift assignment to the business's first branch" do
    create(:branch, business: business)
    insured(create(:user, business: business), 100)

    expect(finalize.branch_id).to eq(first_branch.id)
  end

  it "reuses an existing (even inactive) Social Insurance category" do
    category = create(:expense_category, business: business, name: "Social Insurance", active: false)
    insured(create(:user, business: business), 100)

    expect(finalize.expense_category).to eq(category)
    expect(business.expense_categories.count).to eq(1)
  end

  it "continues the business's expense reference sequence" do
    create(:expense, business: business, branch: first_branch, reference_number: "EXP-000041")
    insured(create(:user, business: business), 100)

    expect(finalize.reference_number).to eq("EXP-000042")
  end

  it "creates nothing on the paid transition (only at finalization)" do
    insured(create(:user, business: business), 100)
    finalize

    expect { Payroll::Approver.advance(period: period.reload, by: owner) }.not_to change(Expense, :count)
    expect(period.reload.status).to eq("paid")
  end
end
