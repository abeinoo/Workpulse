require "rails_helper"

# SEC-M2-12 (found in Milestone 2 — Finance & Sales Expenses M0): an expense
# could be tagged with ANOTHER business's ExpenseTag on create or update. The
# foreign tag's name was rendered on the expense page, and the other business
# could no longer delete its own tag (has_many :expense_taggings,
# restrict_with_error). Tags must now belong to the expense's business: the
# controller refuses foreign tag ids (422, nothing saved) and ExpenseTagging
# validates the business as a backstop.
RSpec.describe "Security: expense tag business isolation", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:branch)   { create(:branch, business: business) }
  let(:category) { ExpenseCategory.create!(business: business, name: "Operations") }
  let!(:own_tag)     { ExpenseTag.create!(business: business, name: "Own tag") }
  let!(:foreign_tag) { ExpenseTag.create!(business: other, name: "Foreign tag") }
  let(:creator) do
    api_user_with(business, :view_expenses, :create_expenses,
                  scopes: { "view_expenses" => "business", "create_expenses" => "business" })
  end

  def expense_params(tag_ids, **overrides)
    { expense: { branch_id: branch.id, expense_category_id: category.id, amount: 10,
                 expense_date: Date.current.to_s, expense_tag_ids: [ "" ] + tag_ids }.merge(overrides) }
  end

  describe "create" do
    before { sign_in creator }

    it "refuses another business's tag: 422, no expense, no tagging" do
      expect { post finance_expenses_path, params: expense_params([ foreign_tag.id ]) }
        .to not_change(Expense, :count).and not_change(ExpenseTagging, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "refuses a mix of own and foreign tags without attaching either" do
      expect { post finance_expenses_path, params: expense_params([ own_tag.id, foreign_tag.id ]) }
        .to not_change(Expense, :count).and not_change(ExpenseTagging, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "still attaches a same-business tag" do
      expect { post finance_expenses_path, params: expense_params([ own_tag.id ]) }.to change(Expense, :count).by(1)
      expense = Expense.order(:id).last
      expect(response).to redirect_to(finance_expense_path(expense))
      expect(expense.expense_tags).to contain_exactly(own_tag)
    end
  end

  describe "update" do
    let!(:expense) do
      sign_in owner
      post finance_expenses_path, params: expense_params([ own_tag.id ])
      Expense.order(:id).last
    end

    before { sign_in owner }

    it "refuses another business's tag: 422, tags and attributes unchanged" do
      patch finance_expense_path(expense), params: { expense: { amount: 99, expense_tag_ids: [ "", own_tag.id, foreign_tag.id ] } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(expense.reload.expense_tags).to contain_exactly(own_tag)
      expect(expense.amount).to eq(10)
    end

    it "still changes same-business tags, including clearing them" do
      second = ExpenseTag.create!(business: business, name: "Second")

      patch finance_expense_path(expense), params: { expense: { expense_tag_ids: [ "", second.id ] } }
      expect(expense.reload.expense_tags).to contain_exactly(second)

      patch finance_expense_path(expense), params: { expense: { expense_tag_ids: [ "" ] } }
      expect(expense.reload.expense_tags).to be_empty
    end
  end

  it "lets the other business delete its own tag after a rejected attempt" do
    sign_in creator
    post finance_expenses_path, params: expense_params([ foreign_tag.id ])

    sign_in create(:user, :owner, business: other)
    expect { delete finance_expense_tag_path(foreign_tag) }.to change(ExpenseTag, :count).by(-1)
  end

  describe "model backstop" do
    it "rejects a tagging whose tag belongs to another business" do
      expense = create(:expense, business: business, expense_category: category, branch: branch)

      tagging = ExpenseTagging.new(expense: expense, expense_tag: foreign_tag)
      expect(tagging).not_to be_valid
      expect(tagging.errors[:expense_tag]).to be_present
      expect(ExpenseTagging.new(expense: expense, expense_tag: own_tag)).to be_valid
    end
  end
end
