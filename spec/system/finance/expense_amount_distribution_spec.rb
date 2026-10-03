require "rails_helper"

# Live "By amount" (بالقيمة) distribution summary on the expense form: the
# amount column replaces the percentage column, the summary tracks expense
# total / distributed / remaining, and Save stays disabled until the branch
# amounts equal the expense amount exactly.
RSpec.describe "Finance::Expenses form — distribution by amount", type: :system do
  let(:business) { create(:business, currency: "EGP") }
  let!(:branch_a) { create(:branch, business: business, name: "Branch A") }
  let!(:branch_b) { create(:branch, business: business, name: "Branch B") }
  let(:owner)    { create(:user, :owner, business: business, preferred_locale: "ar") }
  let!(:category) { create(:expense_category, business: business, name: "Rent") }

  before { sign_in owner }

  def rows = all("tbody[data-line-items-target='rows'] tr[data-line-row]")

  def add_row(branch, amount)
    click_button "+ #{I18n.t('finance.expenses.add_allocation', locale: :ar)}"
    row = rows.last
    row.find("select").select(branch.name)
    row.find("input[data-allocation-target='amtInput']").fill_in(with: amount)
  end

  def summary = find("[data-allocation-target='summary']").text
  def save_disabled? = find("input[type=submit]").disabled?

  it "shows the live summary and only enables Save on an exact match" do
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
    select I18n.t("finance.expenses.modes.manual", locale: :ar), from: "expense_distribution_method"

    expect(page).to have_css("th[data-allocation-target='amtHeader']", visible: true)
    expect(page).to have_no_css("th[data-allocation-target='pctHeader']", visible: true)

    add_row(branch_a, "80")
    within("[data-allocation-target='amountSummary']") do
      expect(page).to have_text("إجمالي المصروف: 100.00 ج.م")
      expect(page).to have_text("إجمالي التوزيع: 80.00 ج.م")
      expect(page).to have_text("المتبقي: 20.00 ج.م")
    end
    expect(summary).to eq("يجب أن يساوي إجمالي توزيع الفروع مبلغ المصروف بالكامل. المتبقي للتوزيع: 20.00 ج.م.")
    expect(save_disabled?).to be true

    add_row(branch_b, "30")
    expect(page).to have_text("إجمالي توزيع الفروع يتجاوز مبلغ المصروف بمقدار 10.00 ج.م.")
    expect(save_disabled?).to be true

    rows.last.find("input[data-allocation-target='amtInput']").fill_in(with: "20")
    within("[data-allocation-target='amountSummary']") do
      expect(page).to have_text("إجمالي التوزيع: 100.00 ج.م")
      expect(page).to have_text("المتبقي: 0.00 ج.م")
    end
    expect(save_disabled?).to be false

    # Editing the expense amount re-validates the distribution live.
    fill_in "expense_amount", with: "120"
    expect(page).to have_text("المتبقي للتوزيع: 20.00 ج.م.")
    expect(save_disabled?).to be true

    fill_in "expense_amount", with: "100"
    expect(save_disabled?).to be false
    find("input[type=submit]").click

    expect(page).to have_current_path(%r{/finance/expenses/\d+})
    expense = Expense.last
    expect(expense.distribution_method).to eq("manual")
    expect(expense.expense_allocations.order(:id).map { |a| [ a.branch_id, a.allocated_amount ] })
      .to eq([ [ branch_a.id, 80 ], [ branch_b.id, 20 ] ])
  end
end
