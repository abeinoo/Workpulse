require "rails_helper"

RSpec.describe "Finance::Expenses#cancel", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:category) { create(:expense_category, business: business) }
  let(:owner)    { create(:user, :owner, business: business) }

  let(:employee_role) do
    create(:permission_role, business: business, permissions: %w[view_expenses create_expenses],
           permission_scopes: { "view_expenses" => "business" })
  end
  let(:employee) { create(:user, business: business, permission_role: employee_role) }
  let(:other)    { create(:user, business: business, permission_role: employee_role) }

  it "lets the requester cancel their own pending expense" do
    sign_in employee
    expense = create(:expense, :pending, business: business, branch: branch,
                      expense_category: category, created_by: employee, deduct_from_balance: false)

    patch cancel_finance_expense_path(expense), params: { cancellation_reason: "No longer needed" }

    expect(response).to redirect_to(finance_expense_path(expense))
    expense.reload
    expect(expense.status).to eq("cancelled")
    expect(expense.cancelled_by).to eq(employee)
    expect(expense.cancellation_reason).to eq("No longer needed")
  end

  it "does NOT let a different employee cancel someone else's request" do
    sign_in other
    expense = create(:expense, :pending, business: business, branch: branch,
                      expense_category: category, created_by: employee, deduct_from_balance: false)

    patch cancel_finance_expense_path(expense), params: { cancellation_reason: "x" }

    expect(response).to redirect_to(root_path)
    expect(expense.reload.status).to eq("pending_approval")
  end

  it "does NOT let a rejected expense be cancelled" do
    sign_in employee
    expense = create(:expense, :rejected, business: business, branch: branch,
                      expense_category: category, created_by: employee, deduct_from_balance: false)

    patch cancel_finance_expense_path(expense), params: { cancellation_reason: "x" }

    expect(response).to redirect_to(root_path)
    expect(expense.reload.status).to eq("rejected")
  end

  it "lets a manager with approve_expenses cancel an already-approved expense" do
    sign_in owner
    expense = create(:expense, :approved, business: business, branch: branch,
                      expense_category: category, created_by: employee, deduct_from_balance: false)

    patch cancel_finance_expense_path(expense), params: { cancellation_reason: "Approved by mistake" }

    expect(expense.reload.status).to eq("cancelled")
  end
end
