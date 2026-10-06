require "rails_helper"

# FS-D2 (found in Milestone 2 — Finance & Sales Expenses M1 probing): expense
# category names are unique per business regardless of case (model validation
# and a unique index on lower(name)), but the insurance generator looked the
# "Social Insurance" category up case-sensitively. A business that already had
# "social insurance" could not finalize payroll: the create was rejected
# ("Name has already been taken") and finalization rolled back. The lookup is
# now case-insensitive and reuses the existing category.
RSpec.describe "Payroll insurance expense category (FS-D2)" do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let!(:branch)  { create(:branch, business: business) }
  let(:period) do
    create(:payroll_period, business: business, period_year: 2026, period_month: 6, status: "branch_review_completed")
  end

  before do
    create(:payroll_entry, payroll_period: period, user: create(:user, business: business),
                           insured: true, employer_insurance_amount: 100)
  end

  def finalize = Payroll::Approver.advance(period: period, by: owner)
  def insurance_expense = Expense.find_by!(source_payroll_period: period)
  def insurance_categories = business.expense_categories.where("LOWER(name) = ?", "social insurance")

  %w[social\ insurance SOCIAL\ INSURANCE sOcIaL\ InSuRaNcE].each do |name|
    it "finalizes and reuses an existing #{name.inspect} category without creating a duplicate" do
      existing = create(:expense_category, business: business, name: name)

      result = finalize

      expect(result).to be_success
      expect(period.reload.status).to eq("finalized")
      expect(insurance_categories.count).to eq(1)
      expect(insurance_expense).to have_attributes(expense_category_id: existing.id, amount: 100, status: "approved")
    end
  end

  it "still reuses an existing canonical \"Social Insurance\" category" do
    existing = create(:expense_category, business: business, name: "Social Insurance")

    expect(finalize).to be_success
    expect(insurance_categories.count).to eq(1)
    expect(insurance_expense.expense_category).to eq(existing)
  end

  it "still creates the canonical \"Social Insurance\" category when none exists" do
    expect { finalize }.to change(business.expense_categories, :count).by(1)

    expect(insurance_expense.expense_category).to have_attributes(name: "Social Insurance", active: true)
  end

  it "never reuses another business's insurance category" do
    foreign = create(:expense_category, business: create(:business), name: "social insurance")

    expect(finalize).to be_success

    expect(insurance_expense.expense_category).not_to eq(foreign)
    expect(insurance_expense.expense_category.business).to eq(business)
    expect(foreign.reload.expenses).to be_empty
  end
end
