require "rails_helper"

# Characterization (Milestone 2 — Finance & Sales Expenses, M1) — CURRENT
# request-level visibility and edit rules for expenses. Policy-level scope
# (in-scope / own / shared-allocated / owner) is in spec/policies/expense_policy_spec.rb;
# approval, cancellation, payments and allocations in the request and service
# specs under spec/requests/finance/ and spec/services/finance/.
#
# Requests that end in a rescued 404 are kept one per example.
RSpec.describe "Characterization: expense visibility and edit rules", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let(:category) { create(:expense_category, business: business) }
  let(:manager) do
    api_user_with(business, :view_expenses, :create_expenses, :edit_expenses,
                  scopes: { "view_expenses" => "branch", "create_expenses" => "branch", "edit_expenses" => "branch" })
      .tap { |user| branch_a.update_column(:branch_manager_id, user.id) }
  end

  let!(:expense_a) { create(:expense, business: business, branch: branch_a, expense_category: category, reference_number: "EXP-000101") }
  let!(:expense_b) { create(:expense, business: business, branch: branch_b, expense_category: category, reference_number: "EXP-000102") }

  def expect_denied
    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
  end

  describe "listing" do
    it "shows a branch-scoped manager only the managed branch's expenses" do
      sign_in manager
      get finance_expenses_path

      expect(response.body).to include("EXP-000101")
      expect(response.body).not_to include("EXP-000102")
    end

    it "shows the owner every expense of the business, and none of another business" do
      create(:expense, reference_number: "EXP-000999")
      sign_in owner
      get finance_expenses_path

      expect(response.body).to include("EXP-000101", "EXP-000102")
      expect(response.body).not_to include("EXP-000999")
    end
  end

  it "returns 404 for another branch's expense to a branch-scoped manager" do
    sign_in manager
    get finance_expense_path(expense_b)
    expect(response).to have_http_status(:not_found)
  end

  it "returns 404 for another business's expense, even to the owner" do
    sign_in owner
    get finance_expense_path(create(:expense))
    expect(response).to have_http_status(:not_found)
  end

  describe "edit rules by status" do
    before { sign_in manager }

    it "submits a draft for approval" do
      patch submit_finance_expense_path(expense_a)

      expect(expense_a.reload).to be_pending_approval
      expect(flash[:notice]).to be_present
    end

    it "lets an editor change a pending expense, but not an approved one" do
      expense_a.update_column(:status, "pending_approval")
      patch finance_expense_path(expense_a), params: { expense: { amount: 55 } }
      expect(expense_a.reload.amount).to eq(55)

      expense_a.update_column(:status, "approved")
      patch finance_expense_path(expense_a), params: { expense: { amount: 77 } }
      expect_denied
      expect(expense_a.reload.amount).to eq(55)
    end

    it "only deletes drafts" do
      expense_a.update_column(:status, "approved")
      expect { delete finance_expense_path(expense_a) }.not_to change(Expense, :count)
      expect_denied

      expense_a.update_column(:status, "draft")
      expect { delete finance_expense_path(expense_a) }.to change(Expense, :count).by(-1)
    end
  end
end
