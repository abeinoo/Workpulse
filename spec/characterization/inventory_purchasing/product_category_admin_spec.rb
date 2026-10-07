require "rails_helper"

# Characterization (Pilot 7 — Inventory & Purchasing Product Catalogue, M1) —
# CURRENT behaviour of product-category administration
# (Inventory::ProductCategoriesController + ProductCategoryPolicy behind the
# inventory gate). A product's reference to another business's category is
# pinned by spec/requests/security/product_category_business_scope_spec.rb
# (SEC-P6-5) and product_references_spec.rb, and not repeated here. How the
# active flag affects the product screens is in product_catalogue_usage_spec.rb.
#
# Requests that end in a rescued 404 are kept one per example.
RSpec.describe "Characterization: product category administration", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:category)         { business.product_categories.create!(name: "Beta Category", description: "Soaps") }
  let!(:foreign_category) { other.product_categories.create!(name: "Foreign Category") }

  let(:viewer)       { api_user_with(business, :view_inventory) }
  let(:manager)      { api_user_with(business, :view_inventory, :manage_inventory) }
  let(:products_mgr) { api_user_with(business, :view_inventory, :manage_products) }
  let(:reports_only) { api_user_with(business, :view_inventory_reports) }
  let(:employee)     { create(:user, business: business) }

  def new_product(sku, category)
    business.products.create!(name: "Product #{sku}", sku: sku, initial_cost_price: 1, average_cost_price: 1,
                              product_category: category)
  end

  def expect_denied
    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
  end

  describe "CRUD (manage_inventory)" do
    before { sign_in manager }

    it "index lists the business's categories by name with description, status and product count, never another business's" do
      business.product_categories.create!(name: "Alpha Category", active: false)
      new_product("C-1", category)
      get inventory_product_categories_path

      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body.index("Alpha Category")).to be < body.index("Beta Category")
      expect(body).to match(%r{Alpha Category</td>\s*<td[^>]*>—</td>\s*<td>\s*<span class="badge">#{I18n.t("inventory.product_categories.statuses.inactive")}</span>.*?<td[^>]*>0</td>}m)
      expect(body).to match(%r{Beta Category</td>\s*<td[^>]*>Soaps</td>\s*<td>\s*<span class="badge badge-success">#{I18n.t("inventory.product_categories.statuses.active")}</span>.*?<td[^>]*>1</td>}m)
      expect(body).not_to include("Foreign Category")
    end

    it "new and edit render (there is no show page)" do
      get new_inventory_product_category_path
      expect(response).to have_http_status(:ok)
      get edit_inventory_product_category_path(category)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Beta Category", "Soaps")
    end

    it "creates a category in the actor's business (active by default, description optional) with a notice" do
      expect { post inventory_product_categories_path, params: { product_category: { name: "Gamma Category" } } }
        .to change(business.product_categories, :count).by(1)

      expect(response).to redirect_to(inventory_product_categories_path)
      expect(flash[:notice]).to eq(I18n.t("inventory.product_categories.created"))
      expect(business.product_categories.find_by!(name: "Gamma Category")).to have_attributes(active: true, description: nil)
    end

    it "stores a free-text description of any length and the active flag as submitted" do
      long = "Soaps, detergents and other cleaning supplies. " * 20
      post inventory_product_categories_path,
           params: { product_category: { name: "Cleaning", description: long, active: "0" } }

      expect(business.product_categories.find_by!(name: "Cleaning")).to have_attributes(description: long, active: false)
    end

    it "re-renders 422 for a blank or over-long (> 120) name" do
      [ "", "x" * 121 ].each do |name|
        expect { post inventory_product_categories_path, params: { product_category: { name: name } } }
          .not_to change(ProductCategory, :count)
        expect(response).to have_http_status(:unprocessable_entity)
      end
    end

    it "names are unique within the business ignoring case (422), but another business may reuse one" do
      expect { post inventory_product_categories_path, params: { product_category: { name: "BETA category" } } }
        .not_to change(ProductCategory, :count)
      expect(response).to have_http_status(:unprocessable_entity)

      post inventory_product_categories_path, params: { product_category: { name: "Foreign Category" } }
      expect(business.product_categories.find_by(name: "Foreign Category")).to be_present
    end

    it "updates name, description and active with a notice, and re-renders 422 on a duplicate name" do
      patch inventory_product_category_path(category),
            params: { product_category: { name: "Beta Renamed", description: "", active: "0" } }
      expect(response).to redirect_to(inventory_product_categories_path)
      expect(flash[:notice]).to eq(I18n.t("inventory.product_categories.updated"))
      expect(category.reload).to have_attributes(name: "Beta Renamed", description: "", active: false)

      business.product_categories.create!(name: "Taken")
      patch inventory_product_category_path(category), params: { product_category: { name: "taken" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(category.reload.name).to eq("Beta Renamed")
    end

    it "deactivating a category leaves its products assigned to it" do
      product = new_product("C-1", category)
      patch inventory_product_category_path(category), params: { product_category: { active: "0" } }

      expect(category.reload.active).to be(false)
      expect(product.reload.product_category).to eq(category)
    end

    it "ignores a submitted business_id on create and on update" do
      post inventory_product_categories_path, params: { product_category: { name: "Placed", business_id: other.id } }
      expect(ProductCategory.find_by!(name: "Placed").business_id).to eq(business.id)

      patch inventory_product_category_path(category), params: { product_category: { name: "Moved?", business_id: other.id } }
      expect(category.reload).to have_attributes(name: "Moved?", business_id: business.id)
    end
  end

  describe "destroy (restrict_with_error on products)" do
    before { sign_in manager }

    it "deletes an unused category with a notice" do
      delete inventory_product_category_path(category)

      expect(response).to redirect_to(inventory_product_categories_path)
      expect(flash[:notice]).to eq(I18n.t("inventory.product_categories.destroyed"))
      expect(ProductCategory).not_to exist(category.id)
    end

    it "refuses a category used by a product: redirect with the restrict error as the alert, both kept" do
      product = new_product("C-1", category)
      delete inventory_product_category_path(category)

      expect(response).to redirect_to(inventory_product_categories_path)
      expect(flash[:notice]).to be_nil
      expect(flash[:alert]).to be_present
      expect(ProductCategory).to exist(category.id)
      expect(product.reload.product_category).to eq(category)
    end

    it "an inactive category used by a product is refused the same way" do
      new_product("C-1", category)
      category.update!(active: false)
      delete inventory_product_category_path(category)

      expect(flash[:alert]).to be_present
      expect(ProductCategory).to exist(category.id)
    end
  end

  describe "authorization (ProductCategoryPolicy behind the inventory gate)" do
    it "view_inventory: may list; may not open the forms, create, update or delete" do
      sign_in viewer
      get inventory_product_categories_path
      expect(response).to have_http_status(:ok)

      get new_inventory_product_category_path
      expect_denied
      get edit_inventory_product_category_path(category)
      expect_denied
      expect { post inventory_product_categories_path, params: { product_category: { name: "Hacked" } } }
        .not_to change(ProductCategory, :count)
      expect_denied
      patch inventory_product_category_path(category), params: { product_category: { name: "Hacked", active: "0" } }
      expect_denied
      delete inventory_product_category_path(category)
      expect_denied
      expect(category.reload).to have_attributes(name: "Beta Category", active: true)
    end

    it "manage_products (with its view_inventory dependency): full administration" do
      sign_in products_mgr
      post inventory_product_categories_path, params: { product_category: { name: "Gamma Category" } }
      patch inventory_product_category_path(category), params: { product_category: { name: "Beta Renamed" } }
      created = business.product_categories.find_by!(name: "Gamma Category")
      delete inventory_product_category_path(created)

      expect(category.reload.name).to eq("Beta Renamed")
      expect(ProductCategory).not_to exist(created.id)
    end

    it "the owner has full access" do
      sign_in owner
      post inventory_product_categories_path, params: { product_category: { name: "Gamma Category" } }
      expect(business.product_categories.where(name: "Gamma Category")).to exist
    end

    it "a reports-only user passes the inventory gate but not ProductCategoryPolicy#index?" do
      sign_in reports_only
      get inventory_product_categories_path
      expect_denied
    end

    it "a user without any inventory permission is stopped by the inventory gate" do
      sign_in employee
      get inventory_product_categories_path
      expect_denied
      expect { post inventory_product_categories_path, params: { product_category: { name: "Hacked" } } }
        .not_to change(ProductCategory, :count)
      expect_denied
    end
  end

  describe "business isolation (404, nothing changed)" do
    before { sign_in manager }

    it "cannot open another business's edit form" do
      get edit_inventory_product_category_path(foreign_category)
      expect(response).to have_http_status(:not_found)
    end

    it "cannot update another business's category" do
      patch inventory_product_category_path(foreign_category), params: { product_category: { name: "Hacked", active: "0" } }
      expect(response).to have_http_status(:not_found)
      expect(foreign_category.reload).to have_attributes(name: "Foreign Category", active: true)
    end

    it "cannot delete another business's category" do
      delete inventory_product_category_path(foreign_category)
      expect(response).to have_http_status(:not_found)
      expect(ProductCategory).to exist(foreign_category.id)
    end

    it "the owner of another business is equally refused" do
      sign_in owner
      delete inventory_product_category_path(foreign_category)
      expect(response).to have_http_status(:not_found)
      expect(ProductCategory).to exist(foreign_category.id)
    end
  end

  describe "P7-D2 (known defect, pinned): the success notices have no translation" do
    it "inventory.product_categories.created / updated / destroyed are missing in en and ar" do
      %w[created updated destroyed].product(%i[en ar]).each do |key, locale|
        expect(I18n.exists?("inventory.product_categories.#{key}", locale)).to be(false), "#{locale}.#{key}"
      end

      sign_in manager
      delete inventory_product_category_path(category)
      expect(flash[:notice]).to eq("Translation missing: en.inventory.product_categories.destroyed")
    end
  end

  describe "model" do
    it "belongs to a business and has many products; active by default; scoped helpers" do
      expect(ProductCategory.reflect_on_association(:business).macro).to eq(:belongs_to)
      expect(ProductCategory.reflect_on_association(:products).options).to include(dependent: :restrict_with_error)
      expect(Business.reflect_on_association(:product_categories).options).to include(dependent: :destroy)

      inactive = business.product_categories.create!(name: "Old", active: false)
      expect(ProductCategory.for_business(business)).to contain_exactly(category, inactive)
      expect(ProductCategory.for_business(business).active).to contain_exactly(category)
      expect(ProductCategory.new(name: "No Business")).not_to be_valid
    end

    it "the case-insensitive uniqueness is also a database index (business_id, lower(name))" do
      expect { ProductCategory.new(business: business, name: "BETA CATEGORY").save(validate: false) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
