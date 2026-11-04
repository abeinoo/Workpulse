require "rails_helper"

# Expense#unallocated: a payroll-generated business-level cost with no branch and
# no split (the employer insurance of floating employees). Every other expense
# keeps needing a branch or a complete split.
RSpec.describe Expense, "unallocated" do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:period)   { create(:payroll_period, business: business) }

  def unallocated(**attrs)
    build(:expense, :approved, business: business, branch: nil, source_payroll_period: period, unallocated: true, **attrs)
  end

  it "accepts a payroll-generated expense with no branch and no split" do
    expense = unallocated
    expect(expense).to be_valid

    expense.save!
    expect(expense.reload).to have_attributes(unallocated: true, branch_id: nil, is_shared: false, distribution_method: nil)
  end

  it "keeps refusing an ordinary expense with neither a branch nor a split" do
    expense = build(:expense, :approved, business: business, branch: nil)

    expect(expense).not_to be_valid
    expect(expense.errors.of_kind?(:expense_allocations, :at_least_one_branch_required)).to be(true)
  end

  it "refuses unallocated on an expense that is not payroll-generated" do
    expense = unallocated(source_payroll_period: nil)

    expect(expense).not_to be_valid
    expect(expense.errors.of_kind?(:base, :unallocated_payroll_only)).to be(true)
  end

  it "refuses unallocated with a branch" do
    expense = unallocated(branch: branch)

    expect(expense).not_to be_valid
    expect(expense.errors.of_kind?(:base, :unallocated_payroll_only)).to be(true)
  end

  it "refuses unallocated with a branch split" do
    expense = unallocated(distribution_method: "percentage")
    expense.expense_allocations.build(branch: branch, allocation_percentage: 100, allocated_amount: 100)

    expect(expense).not_to be_valid
    expect(expense.errors.of_kind?(:expense_allocations, :unallocated_without_allocations)).to be(true)
  end

  it "is enforced by the database for writes that skip validations" do
    ordinary = create(:expense, :approved, business: business, branch: branch)

    expect { ordinary.update_columns(unallocated: true) }.to raise_error(ActiveRecord::StatementInvalid, /expenses_unallocated_payroll_only/)
  end

  it "cannot be edited once recorded (system-generated), only voided" do
    expense = unallocated.tap(&:save!)

    expect { expense.update!(unallocated: false) }.to raise_error(ActiveRecord::ActiveRecordError)
    expect(expense.reload.unallocated).to be(true)
    expect { expense.update!(voided_at: Time.current, status: "cancelled") }.not_to raise_error
  end
end
