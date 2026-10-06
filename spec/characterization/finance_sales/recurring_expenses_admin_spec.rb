require "rails_helper"

# Characterization (Milestone 2 — Finance & Sales Expenses, M1) — CURRENT
# recurring-expense administration (Finance::RecurringExpensesController +
# RecurringExpensePolicy): create/update/delete, the manual `generate` action,
# write scope, read-only access and business isolation. Generation rules
# (schedule guards, duplicate prevention, shared allocations) are in
# spec/services/finance/recurring_expense_generator_spec.rb and the job spec.
#
# Requests that end in a rescued 404 are kept one per example.
RSpec.describe "Characterization: recurring expenses administration", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let(:category) { create(:expense_category, business: business) }
  let(:manager) do
    api_user_with(business, :view_expenses, :manage_recurring_expenses,
                  scopes: { "view_expenses" => "branch", "manage_recurring_expenses" => "branch" })
      .tap { |user| branch_a.update_column(:branch_manager_id, user.id) }
  end
  let(:viewer) { api_user_with(business, :view_expenses, scopes: { "view_expenses" => "business" }) }

  def template_params(branch, **overrides)
    { recurring_expense: { branch_id: branch.id, expense_category_id: category.id, amount: 200, frequency: "monthly",
                           start_date: Date.current.to_s, next_run_on: Date.current.to_s }.merge(overrides) }
  end

  def expect_denied
    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
  end

  describe "write scope (manage_recurring_expenses, branch scope)" do
    before { sign_in manager }

    it "creates a template for a managed branch, attributed to the actor" do
      expect { post finance_recurring_expenses_path, params: template_params(branch_a) }.to change(RecurringExpense, :count).by(1)

      template = RecurringExpense.last
      expect(response).to redirect_to(finance_recurring_expense_path(template))
      expect(flash[:notice]).to eq(I18n.t("finance.recurring.created"))
      expect(template).to have_attributes(business_id: business.id, branch_id: branch_a.id, created_by_id: manager.id, amount: 200)
    end

    it "refuses a template for a branch outside the scope" do
      expect { post finance_recurring_expenses_path, params: template_params(branch_b) }.not_to change(RecurringExpense, :count)
      expect_denied
    end

    it "does not show another branch's template (404)" do
      get finance_recurring_expense_path(create(:recurring_expense, business: business, expense_category: category, branch: branch_b))
      expect(response).to have_http_status(:not_found)
    end

    it "re-renders the form with 422 for an invalid template" do
      expect { post finance_recurring_expenses_path, params: template_params(branch_a, amount: 0) }.not_to change(RecurringExpense, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "generate" do
    let!(:template) { create(:recurring_expense, business: business, expense_category: category, branch: branch_a, amount: 300) }

    before { sign_in manager }

    it "creates a pending expense from the template and opens it" do
      expect { post generate_finance_recurring_expense_path(template) }.to change(Expense, :count).by(1)

      expense = Expense.last
      expect(response).to redirect_to(finance_expense_path(expense))
      expect(flash[:notice]).to eq(I18n.t("finance.recurring.generated"))
      expect(expense).to have_attributes(status: "pending_approval", amount: 300, source_recurring_expense_id: template.id,
                                         branch_id: branch_a.id)
      expect(expense).to be_system_generated
    end

    it "advances the schedule, so generating again creates the next period's expense" do
      post generate_finance_recurring_expense_path(template)
      next_run = template.reload.next_run_on
      expect(next_run).to eq(Date.current >> 1)

      expect { post generate_finance_recurring_expense_path(template) }.to change(Expense, :count).by(1)
      expect(Expense.where(source_recurring_expense: template).pluck(:expense_date)).to contain_exactly(Date.current, next_run)
    end
  end

  describe "read-only access (view_expenses only)" do
    let!(:template) { create(:recurring_expense, business: business, expense_category: category, branch: branch_b, amount: 100) }

    before { sign_in viewer }

    it "can view but not change, generate or delete a template" do
      get finance_recurring_expense_path(template)
      expect(response).to have_http_status(:ok)

      patch finance_recurring_expense_path(template), params: { recurring_expense: { amount: 1 } }
      expect_denied
      expect(template.reload.amount).to eq(100)

      expect { post generate_finance_recurring_expense_path(template) }.not_to change(Expense, :count)
      expect_denied

      expect { delete finance_recurring_expense_path(template) }.not_to change(RecurringExpense, :count)
      expect_denied
    end
  end

  it "returns 404 for another business's template" do
    sign_in owner
    get finance_recurring_expense_path(create(:recurring_expense))
    expect(response).to have_http_status(:not_found)
  end

  it "deleting a template keeps the expenses it generated, detached from it" do
    template = create(:recurring_expense, business: business, expense_category: category, branch: branch_a)
    sign_in owner
    post generate_finance_recurring_expense_path(template)
    generated = Expense.find_by!(source_recurring_expense: template)

    delete finance_recurring_expense_path(template)

    expect(response).to redirect_to(finance_recurring_expenses_path)
    expect(RecurringExpense.exists?(template.id)).to be(false)
    expect(generated.reload.source_recurring_expense_id).to be_nil
  end
end
