require "rails_helper"

# Recurring expense notes (RecurringExpense#notes): optional free text captured
# on the form, listed (clamped) on the index and shown in full on the show
# page. Display only — generation and allocation behaviour are unchanged.
RSpec.describe "Finance recurring expenses — notes", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:branch_a) { create(:branch, business: business, name: "Downtown") }
  let(:branch_b) { create(:branch, business: business, name: "Uptown") }
  let(:category) { create(:expense_category, business: business, name: "Rent") }

  before { sign_in owner }

  def template_params(**overrides)
    { recurring_expense: { branch_id: branch_a.id, expense_category_id: category.id, amount: 200, frequency: "monthly",
                           start_date: Date.current.to_s, next_run_on: Date.current.to_s }.merge(overrides) }
  end

  it "renders the notes textarea on the new form" do
    get new_finance_recurring_expense_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('name="recurring_expense[notes]"')
    expect(response.body).to include(I18n.t("finance.recurring.notes"))
  end

  it "creates a recurring expense with notes" do
    expect { post finance_recurring_expenses_path, params: template_params(notes: "Paid to landlord\nby transfer") }
      .to change(RecurringExpense, :count).by(1)

    expect(RecurringExpense.last.notes).to eq("Paid to landlord\nby transfer")
  end

  it "creates a recurring expense without notes" do
    expect { post finance_recurring_expenses_path, params: template_params }.to change(RecurringExpense, :count).by(1)

    template = RecurringExpense.last
    expect(template.notes).to be_nil
    expect(template).to have_attributes(amount: 200, frequency: "monthly", branch_id: branch_a.id)
  end

  it "keeps notes on the edit form and updates them" do
    template = create(:recurring_expense, business: business, expense_category: category, branch: branch_a, notes: "Old note")

    get edit_finance_recurring_expense_path(template)
    expect(response.body).to include("Old note")

    patch finance_recurring_expense_path(template), params: { recurring_expense: { notes: "New note" } }

    expect(response).to redirect_to(finance_recurring_expense_path(template))
    expect(template.reload).to have_attributes(notes: "New note", amount: 100, frequency: "monthly")
  end

  it "does not copy template notes onto a generated expense" do
    template = create(:recurring_expense, business: business, expense_category: category, branch: branch_a,
                                          notes: "Template-only note", created_by: owner)

    post generate_finance_recurring_expense_path(template)

    expect(Expense.find_by!(source_recurring_expense: template).notes).to be_blank
  end

  describe "index" do
    it "shows each template's notes and leaves blank notes empty" do
      create(:recurring_expense, business: business, expense_category: category, branch: branch_a, notes: "Short note")
      create(:recurring_expense, business: business, expense_category: category, branch: branch_b, notes: "   ")

      get finance_recurring_expenses_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Short note")
      expect(response.body.scan('<td class="expense-list__notes">').size).to eq(1)
      expect(response.body.scan('<td class="expense-list__notes expense-list__notes--empty">').size).to eq(1)
      expect(response.body).not_to include("expense-list__notes-empty")
    end

    it "clamps a long note with an expandable toggle" do
      long = "Long note " * 20
      create(:recurring_expense, business: business, expense_category: category, branch: branch_a, notes: long)

      get finance_recurring_expenses_path

      expect(response.body).to include('<details class="expense-list__note">')
      expect(response.body).to include(I18n.t("finance.expenses.note_more"))
    end
  end

  describe "show" do
    it "shows the summary, schedule, allocations and notes" do
      template = create(:recurring_expense, business: business, expense_category: category, amount: 450,
                                            frequency: "quarterly", end_date: Date.current + 1.year,
                                            notes: "Line one\nLine two")
      template.recurring_expense_allocations.create!(branch: branch_a, allocation_percentage: 60)
      template.recurring_expense_allocations.create!(branch: branch_b, allocation_percentage: 40)

      get finance_recurring_expense_path(template)

      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).to include(I18n.t("finance.recurring.frequencies.quarterly"))
      expect(body).to include(I18n.t("finance.recurring.section_schedule"))
      expect(body).to include(I18n.l(template.end_date, format: :long))
      expect(body).to include(I18n.t("finance.expenses.section_allocations"))
      expect(body).to include("Downtown", "60.00%", "Uptown", "40.00%")
      expect(body).to include(I18n.t("finance.expenses.shared"))
      expect(body).to include("Line one\n<br />Line two")
    end

    it "omits the notes and allocations cards when there are none" do
      template = create(:recurring_expense, business: business, expense_category: category, branch: branch_a)

      get finance_recurring_expense_path(template)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(%(<h2 class="card-title">#{I18n.t('finance.recurring.notes')}</h2>))
      expect(response.body).not_to include(I18n.t("finance.expenses.section_allocations"))
      expect(response.body).to include("Downtown")
    end
  end
end
