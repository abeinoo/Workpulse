require "rails_helper"

# Picking a branch another distribution row already holds clears the new
# row's select (the existing row is untouched), shows the duplicate message,
# and blocks Save; removing the offending row clears the message.
RSpec.describe "Finance::Expenses form — duplicate distribution branch", type: :system do
  let(:business)  { create(:business, currency: "EGP") }
  let!(:branch_a) { create(:branch, business: business, name: "Branch A") }
  let!(:branch_b) { create(:branch, business: business, name: "Branch B") }
  let(:owner)     { create(:user, :owner, business: business, preferred_locale: "ar") }
  let!(:category) { create(:expense_category, business: business, name: "Rent") }

  let(:duplicate_message) { "لا يمكن إضافة نفس الفرع أكثر من مرة في توزيع المصروف." }

  before { sign_in owner }

  def rows = all("tbody[data-line-items-target='rows'] tr[data-line-row]")
  def add_row = click_button("+ #{I18n.t('finance.expenses.add_allocation', locale: :ar)}")
  def duplicate_msg = find("[data-allocation-target='duplicateMsg']", visible: :all)
  def save_disabled? = find("input[type=submit]").disabled?

  def fill_basics(method)
    visit new_finance_expense_path
    select category.name, from: "expense_expense_category_id"
    fill_in "expense_amount", with: "100"
    page.execute_script(<<~JS)
      const el = document.getElementById("expense_expense_date");
      el.value = "2026-08-09";
      el.dispatchEvent(new Event("change", { bubbles: true }));
    JS
    choose "expense_payment_type_installment"
    find("#expense_branch_id").find("option[value='shared']").select_option
    select I18n.t("finance.expenses.modes.#{method}", locale: :ar), from: "expense_distribution_method"
  end

  %w[percentage equal manual].each do |method|
    it "rejects selecting an already-selected branch (#{method})" do
      fill_basics(method)

      add_row
      rows.first.find("select").select(branch_a.name)
      add_row
      rows.last.find("select").select(branch_a.name)

      expect(page).to have_text(duplicate_message)
      expect(rows.first.find("select").value).to eq(branch_a.id.to_s)
      expect(rows.last.find("select").value).to eq("")
      expect(page.evaluate_script('document.querySelector("form").checkValidity()')).to be false

      rows.last.find("select").select(branch_b.name)
      expect(duplicate_msg).not_to be_visible
    end
  end

  it "clears the message when the offending row is removed and saves the distinct rows" do
    fill_basics("equal")

    add_row
    rows.first.find("select").select(branch_a.name)
    add_row
    rows.last.find("select").select(branch_a.name)
    expect(page).to have_text(duplicate_message)

    rows.last.find("button[data-action*='line-items#remove']").click
    expect(duplicate_msg).not_to be_visible
    expect(save_disabled?).to be false

    find("input[type=submit]").click
    expect(page).to have_current_path(%r{/finance/expenses/\d+})
    expect(Expense.last.expense_allocations.map(&:branch_id)).to eq([ branch_a.id ])
  end
end
