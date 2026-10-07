require "rails_helper"

# Characterization (Pilot 7 — Inventory & Purchasing Product Catalogue, M1) —
# CURRENT behaviour of brand administration (Inventory::BrandsController +
# BrandPolicy behind the inventory gate). A product's reference to another
# business's brand is pinned by spec/requests/security/product_brand_business_scope_spec.rb
# (SEC-P6-4) and product_references_spec.rb, and not repeated here.
#
# Requests that end in a rescued 404 are kept one per example.
RSpec.describe "Characterization: brand administration", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:brand)         { business.brands.create!(name: "Beta Brand") }
  let!(:foreign_brand) { other.brands.create!(name: "Foreign Brand") }

  let(:viewer)       { api_user_with(business, :view_inventory) }
  let(:manager)      { api_user_with(business, :view_inventory, :manage_inventory) }
  let(:products_mgr) { api_user_with(business, :view_inventory, :manage_products) }
  let(:reports_only) { api_user_with(business, :view_inventory_reports) }
  let(:employee)     { create(:user, business: business) }

  def new_product(sku, brand)
    business.products.create!(name: "Product #{sku}", sku: sku, initial_cost_price: 1, average_cost_price: 1, brand: brand)
  end

  def expect_denied
    expect(response).to redirect_to(root_path)
    expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
  end

  describe "CRUD (manage_inventory)" do
    before { sign_in manager }

    it "index lists the business's brands ordered by name with their product counts, never another business's" do
      business.brands.create!(name: "Alpha Brand")
      new_product("B-1", brand)
      new_product("B-2", brand)
      get inventory_brands_path

      expect(response).to have_http_status(:ok)
      expect(response.body.index("Alpha Brand")).to be < response.body.index("Beta Brand")
      expect(response.body).to match(%r{Beta Brand</td>\s*<td[^>]*>2</td>})
      expect(response.body).to match(%r{Alpha Brand</td>\s*<td[^>]*>0</td>})
      expect(response.body).not_to include("Foreign Brand")
    end

    it "new and edit render (there is no show page)" do
      get new_inventory_brand_path
      expect(response).to have_http_status(:ok)
      get edit_inventory_brand_path(brand)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Beta Brand")
    end

    it "creates a brand in the actor's business and redirects to the list with a notice" do
      expect { post inventory_brands_path, params: { brand: { name: "Gamma Brand" } } }
        .to change(business.brands, :count).by(1)

      expect(response).to redirect_to(inventory_brands_path)
      expect(flash[:notice]).to eq(I18n.t("inventory.brands.created"))
    end

    it "re-renders 422 for a blank or over-long (> 120) name" do
      [ "", "x" * 121 ].each do |name|
        expect { post inventory_brands_path, params: { brand: { name: name } } }.not_to change(Brand, :count)
        expect(response).to have_http_status(:unprocessable_entity)
      end
      post inventory_brands_path, params: { brand: { name: "x" * 120 } }
      expect(business.brands.find_by(name: "x" * 120)).to be_present
    end

    it "names are unique within the business ignoring case (422), but another business may reuse one" do
      expect { post inventory_brands_path, params: { brand: { name: "beta BRAND" } } }.not_to change(Brand, :count)
      expect(response).to have_http_status(:unprocessable_entity)

      post inventory_brands_path, params: { brand: { name: "Foreign Brand" } }
      expect(business.brands.find_by(name: "Foreign Brand")).to be_present
    end

    it "updates with a notice, and re-renders 422 on an invalid or duplicate name" do
      patch inventory_brand_path(brand), params: { brand: { name: "Beta Renamed" } }
      expect(response).to redirect_to(inventory_brands_path)
      expect(flash[:notice]).to eq(I18n.t("inventory.brands.updated"))
      expect(brand.reload.name).to eq("Beta Renamed")

      business.brands.create!(name: "Taken")
      [ "", "TAKEN" ].each do |name|
        patch inventory_brand_path(brand), params: { brand: { name: name } }
        expect(response).to have_http_status(:unprocessable_entity)
        expect(brand.reload.name).to eq("Beta Renamed")
      end
    end

    it "ignores a submitted business_id on create and on update" do
      post inventory_brands_path, params: { brand: { name: "Placed", business_id: other.id } }
      expect(Brand.find_by!(name: "Placed").business_id).to eq(business.id)

      patch inventory_brand_path(brand), params: { brand: { name: "Moved?", business_id: other.id } }
      expect(brand.reload).to have_attributes(name: "Moved?", business_id: business.id)
    end
  end

  describe "destroy (restrict_with_error on products)" do
    before { sign_in manager }

    it "deletes an unused brand with a notice" do
      delete inventory_brand_path(brand)

      expect(response).to redirect_to(inventory_brands_path)
      expect(flash[:notice]).to eq(I18n.t("inventory.brands.destroyed"))
      expect(Brand).not_to exist(brand.id)
    end

    it "refuses a brand used by a product: redirect with the restrict error as the alert, brand and product kept" do
      product = new_product("B-1", brand)
      delete inventory_brand_path(brand)

      expect(response).to redirect_to(inventory_brands_path)
      expect(flash[:notice]).to be_nil
      expect(flash[:alert]).to be_present
      expect(Brand).to exist(brand.id)
      expect(product.reload.brand).to eq(brand)
    end

    it "an archived product still blocks the delete" do
      new_product("B-1", brand).update!(active: false)
      delete inventory_brand_path(brand)

      expect(flash[:alert]).to be_present
      expect(Brand).to exist(brand.id)
    end
  end

  describe "authorization (BrandPolicy behind the inventory gate)" do
    it "view_inventory: may list; may not open the forms, create, update or delete" do
      sign_in viewer
      get inventory_brands_path
      expect(response).to have_http_status(:ok)

      get new_inventory_brand_path
      expect_denied
      get edit_inventory_brand_path(brand)
      expect_denied
      expect { post inventory_brands_path, params: { brand: { name: "Hacked" } } }.not_to change(Brand, :count)
      expect_denied
      patch inventory_brand_path(brand), params: { brand: { name: "Hacked" } }
      expect_denied
      delete inventory_brand_path(brand)
      expect_denied
      expect(brand.reload.name).to eq("Beta Brand")
    end

    it "manage_products (with its view_inventory dependency): full administration" do
      sign_in products_mgr
      post inventory_brands_path, params: { brand: { name: "Gamma Brand" } }
      patch inventory_brand_path(brand), params: { brand: { name: "Beta Renamed" } }
      created = business.brands.find_by!(name: "Gamma Brand")
      delete inventory_brand_path(created)

      expect(brand.reload.name).to eq("Beta Renamed")
      expect(Brand).not_to exist(created.id)
    end

    it "manage_products cannot be granted without view_inventory (permission dependency)" do
      role = business.permission_roles.build(name: "Products only", permissions: %w[manage_products])
      expect(role).not_to be_valid
      expect(role.errors[:permissions].join).to include("view_inventory")
    end

    it "the owner has full access" do
      sign_in owner
      post inventory_brands_path, params: { brand: { name: "Gamma Brand" } }
      expect(business.brands.where(name: "Gamma Brand")).to exist
    end

    it "a reports-only user passes the inventory gate but not BrandPolicy#index?" do
      sign_in reports_only
      get inventory_brands_path
      expect_denied
    end

    it "a user without any inventory permission is stopped by the inventory gate" do
      sign_in employee
      get inventory_brands_path
      expect_denied
      expect { post inventory_brands_path, params: { brand: { name: "Hacked" } } }.not_to change(Brand, :count)
      expect_denied
    end
  end

  describe "business isolation (404, nothing changed)" do
    before { sign_in manager }

    it "cannot open another business's edit form" do
      get edit_inventory_brand_path(foreign_brand)
      expect(response).to have_http_status(:not_found)
    end

    it "cannot update another business's brand" do
      patch inventory_brand_path(foreign_brand), params: { brand: { name: "Hacked" } }
      expect(response).to have_http_status(:not_found)
      expect(foreign_brand.reload.name).to eq("Foreign Brand")
    end

    it "cannot delete another business's brand" do
      delete inventory_brand_path(foreign_brand)
      expect(response).to have_http_status(:not_found)
      expect(Brand).to exist(foreign_brand.id)
    end

    it "the owner of another business is equally refused" do
      sign_in owner
      patch inventory_brand_path(foreign_brand), params: { brand: { name: "Hacked" } }
      expect(response).to have_http_status(:not_found)
      expect(foreign_brand.reload.name).to eq("Foreign Brand")
    end
  end

  describe "P7-D2 (known defect, pinned): the success notices have no translation" do
    it "inventory.brands.created / updated / destroyed are missing in en and ar, so the notice reads 'Translation missing'" do
      %w[created updated destroyed].product(%i[en ar]).each do |key, locale|
        expect(I18n.exists?("inventory.brands.#{key}", locale)).to be(false), "#{locale}.#{key}"
      end

      sign_in manager
      post inventory_brands_path, params: { brand: { name: "Gamma Brand" } }
      expect(flash[:notice]).to eq("Translation missing: en.inventory.brands.created")
    end
  end

  describe "model" do
    it "belongs to a business and has many products; scoped helpers" do
      expect(Brand.reflect_on_association(:business).macro).to eq(:belongs_to)
      expect(Brand.reflect_on_association(:products).options).to include(dependent: :restrict_with_error)
      expect(Business.reflect_on_association(:brands).options).to include(dependent: :destroy)
      expect(Brand.for_business(business)).to contain_exactly(brand)
      expect(Brand.new(name: "No Business")).not_to be_valid
    end

    it "the case-insensitive uniqueness is also a database index (business_id, lower(name))" do
      expect { Brand.new(business: business, name: "BETA BRAND").save(validate: false) }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
