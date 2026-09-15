require "rails_helper"

# The "Paid from my balance/custody" control must only ever apply to a
# Direct expense — an Installment expense's payment source is decided per
# actual payment, later, from the Show page. Regression coverage for the
# fix: selecting "Installment" must hide the checkbox (and, if it was
# checked while "Direct" was selected, uncheck it) so nothing leaks through
# on submit — payment_type_controller.js.
RSpec.describe "Finance::Expenses new form — payment source visibility", type: :system do
  let(:business) { create(:business) }
  let!(:branch)  { create(:branch, business: business, name: "Downtown Branch") }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:category) { create(:expense_category, business: business, name: "Marketing") }
  let!(:type)    { create(:expense_type, business: business, expense_category: category, name: "Ads") }
  let!(:account) { create(:custody_account, business: business, user: owner, name: "Owner Float") }

  before { sign_in owner }

  it "shows the balance checkbox for Direct, hides and unchecks it for Installment" do
    visit new_finance_expense_path

    expect(page).to have_field("expense_deduct_from_balance", visible: true)
    check "expense_deduct_from_balance"
    expect(page).to have_field("expense_deduct_from_balance", checked: true)

    choose "expense_payment_type_installment"

    expect(page).to have_field("expense_deduct_from_balance", visible: false)
    checkbox = find("#expense_deduct_from_balance", visible: false)
    expect(checkbox.checked?).to be false

    choose "expense_payment_type_direct"
    expect(page).to have_field("expense_deduct_from_balance", visible: true)
  end

  it "submits an installment expense with deduct_from_balance false even after toggling the checkbox pre-switch" do
    visit new_finance_expense_path

    select category.name, from: "expense_expense_category_id"
    select type.name, from: "expense_expense_type_id"
    fill_in "expense_amount", with: "8000"
    page.execute_script(<<~JS)
      const el = document.getElementById("expense_expense_date");
      el.value = "2026-09-15";
      el.dispatchEvent(new Event("change", { bubbles: true }));
    JS

    check "expense_deduct_from_balance" # user first ticks it under Direct...
    choose "expense_payment_type_installment" # ...then switches to Installment
    select branch.name, from: "expense_branch_id"

    find("input[type=submit]").click

    expect(page).to have_current_path(%r{/finance/expenses/\d+})
    expense = Expense.last
    expect(expense.payment_type).to eq("installment")
    expect(expense.deduct_from_balance).to eq(false)
    expect(expense.total_settled_amount).to eq(0)
  end
end
