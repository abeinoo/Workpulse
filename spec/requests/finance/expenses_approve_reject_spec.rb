require "rails_helper"

RSpec.describe "Finance::Expenses#approve / #reject", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:category) { create(:expense_category, business: business) }
  let(:owner)    { create(:user, :owner, business: business) }

  let(:employee_role) do
    create(:permission_role, business: business, permissions: %w[view_expenses create_expenses],
           permission_scopes: { "view_expenses" => "business" })
  end
  let(:employee) { create(:user, business: business, permission_role: employee_role) }

  describe "#approve" do
    it "redirects to the expense show page by default" do
      sign_in owner
      expense = create(:expense, :pending, business: business, branch: branch,
                        expense_category: category, created_by: employee, deduct_from_balance: false)

      patch approve_finance_expense_path(expense)

      expect(response).to redirect_to(finance_expense_path(expense))
      expect(expense.reload.status).to eq("approved")
    end

    it "redirects back to the filtered index when triggered from the index page" do
      sign_in owner
      expense = create(:expense, :pending, business: business, branch: branch,
                        expense_category: category, created_by: employee, deduct_from_balance: false)

      patch approve_finance_expense_path(expense),
            params: { from_index: 1, status: "approved", branch_id: branch.id }

      expect(response).to redirect_to(finance_expenses_path(status: "approved", branch_id: branch.id))
      expect(expense.reload.status).to eq("approved")
    end
  end

  describe "#reject" do
    it "redirects to the expense show page by default" do
      sign_in owner
      expense = create(:expense, :pending, business: business, branch: branch,
                        expense_category: category, created_by: employee, deduct_from_balance: false)

      patch reject_finance_expense_path(expense), params: { rejection_reason: "Not needed" }

      expect(response).to redirect_to(finance_expense_path(expense))
      expect(expense.reload.status).to eq("rejected")
    end

    it "redirects back to the filtered index when triggered from the index page" do
      sign_in owner
      expense = create(:expense, :pending, business: business, branch: branch,
                        expense_category: category, created_by: employee, deduct_from_balance: false)

      patch reject_finance_expense_path(expense),
            params: { from_index: 1, rejection_reason: "Not needed", status: "rejected", created_by_id: employee.id }

      expect(response).to redirect_to(finance_expenses_path(status: "rejected", created_by_id: employee.id))
      expect(expense.reload.status).to eq("rejected")
    end
  end
end
