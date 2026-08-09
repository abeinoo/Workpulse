require "rails_helper"

RSpec.describe "Finance::Expenses#create", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business, name: "Downtown Branch") }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:category) { create(:expense_category, business: business, name: "Marketing") }
  let!(:type)    { create(:expense_type, business: business, expense_category: category, name: "Ads") }

  before { sign_in owner }

  it "creates the expense and redirects when a specific branch is selected" do
    expect {
      post finance_expenses_path, params: {
        expense: {
          expense_category_id: category.id,
          expense_type_id: type.id,
          amount: "324",
          expense_date: "2026-08-09",
          branch_id: branch.id.to_s,
          deduct_from_balance: "0"
        }
      }
    }.to change(Expense, :count).by(1)

    expense = Expense.last
    expect(response).to redirect_to(finance_expense_path(expense))
    expect(expense.branch).to eq(branch)
    expect(expense.is_shared).to eq(false)
    expect(expense.distribution_method).to be_nil
  end
end
