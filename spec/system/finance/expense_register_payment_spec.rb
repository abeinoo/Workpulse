require "rails_helper"

# End-to-end coverage for the "تسجيل دفعة" button on the Expense Show page:
# it must appear (only for an approved installment expense with a remaining
# balance, for a user with record_expense_payments), navigate to the
# existing finance/expense_payments#new form (no duplicate controller), and
# a full round trip must correctly update the Payment Summary.
RSpec.describe "Finance::Expenses show page — register payment", type: :system do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:category) { create(:expense_category, business: business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:role) do
    create(:permission_role, business: business,
           permissions: %w[view_expenses create_expenses approve_expenses record_expense_payments],
           permission_scopes: { "view_expenses" => "business" })
  end
  let(:payer)   { create(:user, business: business, permission_role: role) }
  let!(:account) { create(:custody_account, business: business, user: payer, name: "Payer Float") }
  let(:expense) do
    create(:expense, :approved, business: business, branch: branch, expense_category: category,
           amount: 1_000, payment_type: "installment", created_by: payer)
  end

  before { sign_in payer }

  it "clicking + تسجيل دفعة opens the existing payment form, and submitting it updates the summary" do
    visit finance_expense_path(expense)

    expect(page).to have_content(I18n.t("finance.expenses.financial_statuses.pending_settlement").upcase)
    click_link I18n.t("finance.expenses.actions.add_payment")

    expect(page).to have_current_path(new_finance_expense_payment_path(expense))

    fill_in "payment_amount", with: "400"
    check "payment_paid_from_balance"
    click_button I18n.t("finance.expenses.actions.record_payment")

    expect(page).to have_current_path(finance_expense_path(expense))
    expect(page.text).to include("400")
    expect(expense.reload.total_settled_amount).to eq(400)
    expect(expense.remaining_settlement_amount).to eq(600)
    expect(Finance::CustodyBalance.new(account).current).to eq(-400)
  end
end
