require "rails_helper"

# Regression coverage for a bug where clicking Save on the New Expense form
# silently did nothing once a specific branch was chosen. Root cause: the
# hidden "Branch Distribution" section contained a `required` <select> for
# distribution_method (and per-row branch/percentage fields). Toggling only
# the ancestor's `hidden` attribute does not exempt those descendants from
# native HTML5 constraint validation, so `form.checkValidity()` stayed false
# and the browser blocked submission with no visible error, no console
# error, and no network request. Fixed in allocation_controller.js by also
# `disabled`-ing those fields whenever the section is irrelevant.
RSpec.describe "Finance::Expenses new form — branch selection", type: :system do
  let(:business) { create(:business) }
  let!(:branch)  { create(:branch, business: business, name: "Downtown Branch") }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:category) { create(:expense_category, business: business, name: "Marketing") }
  let!(:type)    { create(:expense_type, business: business, expense_category: category, name: "Ads") }

  before { sign_in owner }

  it "disables the now-irrelevant distribution fields so the form validates and submits" do
    visit new_finance_expense_path

    select category.name, from: "expense_expense_category_id"
    expect(page).to have_select("expense_expense_type_id", with_options: [ type.name ])
    select type.name, from: "expense_expense_type_id"

    fill_in "expense_amount", with: "324"
    page.execute_script(<<~JS)
      const el = document.getElementById("expense_expense_date");
      el.value = "2026-08-09";
      el.dispatchEvent(new Event("change", { bubbles: true }));
    JS

    uncheck "expense_deduct_from_balance"
    select branch.name, from: "expense_branch_id"

    distribution_select = find("#expense_distribution_method", visible: false)
    expect(distribution_select.disabled?).to be true
    expect(page.evaluate_script('document.querySelector("form").checkValidity()')).to be true

    find("input[type=submit]").click

    expect(page).to have_current_path(%r{/finance/expenses/\d+})
    expense = Expense.last
    expect(expense.branch).to eq(branch)
    expect(expense.amount).to eq(324)
  end
end
