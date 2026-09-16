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

  describe "system-generated expenses" do
    let(:recurring_expense) { create(:recurring_expense, business: business) }

    it "approves a system-generated expense without a 500 (ActiveRecord::ReadOnlyRecord)" do
      sign_in owner
      expense = create(:expense, :pending, business: business, branch: branch,
                        expense_category: category, created_by: employee,
                        deduct_from_balance: false, source_recurring_expense: recurring_expense)

      expect {
        patch approve_finance_expense_path(expense)
      }.not_to raise_error

      expect(response).to redirect_to(finance_expense_path(expense))
      expect(expense.reload.status).to eq("approved")
      expect(expense.approved_by_id).to eq(owner.id)
    end

    it "rejects a system-generated expense without a 500 (ActiveRecord::ReadOnlyRecord)" do
      sign_in owner
      expense = create(:expense, :pending, business: business, branch: branch,
                        expense_category: category, created_by: employee,
                        deduct_from_balance: false, source_recurring_expense: recurring_expense)

      expect {
        patch reject_finance_expense_path(expense), params: { rejection_reason: "Duplicate" }
      }.not_to raise_error

      expect(response).to redirect_to(finance_expense_path(expense))
      expect(expense.reload.status).to eq("rejected")
    end

    it "still blocks a normal edit to a system-generated expense" do
      sign_in owner
      expense = create(:expense, :pending, business: business, branch: branch,
                        expense_category: category, created_by: employee,
                        deduct_from_balance: false, source_recurring_expense: recurring_expense)

      patch finance_expense_path(expense), params: { expense: { amount: 999 } }

      expect(expense.reload.amount).not_to eq(999)
    end

    it "still allows voiding a system-generated expense" do
      sign_in owner
      expense = create(:expense, :approved, business: business, branch: branch,
                        expense_category: category, created_by: employee,
                        deduct_from_balance: false, source_recurring_expense: recurring_expense)

      expect {
        expense.update!(voided_at: Time.current, voided_by_id: owner.id, void_reason: "duplicate charge")
      }.not_to raise_error
      expect(expense.reload.voided_at).to be_present
    end
  end
end
