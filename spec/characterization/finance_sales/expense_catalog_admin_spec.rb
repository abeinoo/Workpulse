require "rails_helper"

# Characterization (Milestone 2 — Finance & Sales Expenses, M1) — CURRENT
# administration of expense categories, types and tags: permissions, business
# isolation, uniqueness, delete restrictions and the types `options` endpoint.
# Tag assignment on expenses (SEC-M2-12) is in
# spec/requests/security/expense_tags_business_scope_spec.rb.
RSpec.describe "Characterization: expense categories, types and tags administration", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:branch)   { create(:branch, business: business) }
  let(:manager) do
    api_user_with(business, :view_expenses, :manage_expense_categories, :manage_expense_types, :manage_expense_tags)
  end
  let(:viewer) { api_user_with(business, :view_expenses) }

  def expect_denied
    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
  end

  describe "permissions" do
    it "lets view_expenses holders list but not change categories, types or tags" do
      sign_in viewer

      [ finance_expense_categories_path, finance_expense_types_path, finance_expense_tags_path ].each do |path|
        get path
        expect(response).to have_http_status(:ok)
      end

      expect { post finance_expense_categories_path, params: { expense_category: { name: "Fuel" } } }
        .not_to change(ExpenseCategory, :count)
      expect_denied
    end

    it "keeps users without any finance permission out of the screens" do
      sign_in create(:user, business: business)
      get finance_expense_categories_path
      expect_denied
    end

    it "lets the manage_* holder create a category, a type under it and a tag" do
      sign_in manager

      post finance_expense_categories_path, params: { expense_category: { name: "Fuel", active: "1" } }
      expect(response).to redirect_to(finance_expense_categories_path)
      expect(flash[:notice]).to eq(I18n.t("finance.categories.created"))
      category = business.expense_categories.find_by!(name: "Fuel")

      post finance_expense_types_path, params: { expense_type: { expense_category_id: category.id, name: "Diesel" } }
      expect(response).to redirect_to(finance_expense_types_path)
      expect(category.expense_types.pluck(:name)).to eq([ "Diesel" ])

      post finance_expense_tags_path, params: { expense_tag: { name: "Project X" } }
      expect(response).to redirect_to(finance_expense_tags_path)
      expect(business.expense_tags.pluck(:name)).to eq([ "Project X" ])
    end
  end

  describe "uniqueness and isolation" do
    before { sign_in manager }

    it "rejects a category name already used in the business, regardless of case (422)" do
      create(:expense_category, business: business, name: "Fuel")

      expect { post finance_expense_categories_path, params: { expense_category: { name: "FUEL" } } }
        .not_to change(ExpenseCategory, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "allows the same category name in another business" do
      create(:expense_category, business: other, name: "Fuel")

      expect { post finance_expense_categories_path, params: { expense_category: { name: "Fuel" } } }
        .to change(business.expense_categories, :count).by(1)
    end

    it "rejects a type under another business's category (422)" do
      foreign_category = create(:expense_category, business: other)

      expect { post finance_expense_types_path, params: { expense_type: { expense_category_id: foreign_category.id, name: "X" } } }
        .not_to change(ExpenseType, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns 404 for another business's category" do
      get edit_finance_expense_category_path(create(:expense_category, business: other))
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "delete restrictions" do
    before { sign_in manager }

    it "refuses to delete a category that has expenses, with an explanatory alert" do
      category = create(:expense_category, business: business)
      create(:expense, business: business, branch: branch, expense_category: category)

      expect { delete finance_expense_category_path(category) }.not_to change(ExpenseCategory, :count)
      expect(response).to redirect_to(finance_expense_categories_path)
      expect(flash[:alert]).to be_present
    end

    it "refuses to delete a tag in use, and deletes an unused one" do
      in_use = create(:expense_tag, business: business)
      create(:expense, business: business, branch: branch).expense_tags << in_use
      unused = create(:expense_tag, business: business)

      expect { delete finance_expense_tag_path(in_use) }.not_to change(ExpenseTag, :count)
      expect(flash[:alert]).to be_present

      expect { delete finance_expense_tag_path(unused) }.to change(ExpenseTag, :count).by(-1)
      expect(flash[:notice]).to eq(I18n.t("finance.tags.deleted"))
    end
  end

  describe "types options endpoint" do
    before { sign_in viewer }

    it "returns the business's active types for a category, ordered, as id/name JSON" do
      category = create(:expense_category, business: business)
      create(:expense_type, business: business, expense_category: category, name: "Zeta")
      create(:expense_type, business: business, expense_category: category, name: "Alpha")
      create(:expense_type, business: business, expense_category: category, name: "Old", active: false)

      get options_finance_expense_types_path(category_id: category.id)

      expect(JSON.parse(response.body).map { |t| t["name"] }).to eq(%w[Alpha Zeta])
      expect(JSON.parse(response.body).first.keys).to contain_exactly("id", "name")
    end

    it "returns nothing for another business's category" do
      foreign_category = create(:expense_category, business: other)
      create(:expense_type, business: other, expense_category: foreign_category)

      get options_finance_expense_types_path(category_id: foreign_category.id)

      expect(JSON.parse(response.body)).to eq([])
    end
  end
end
