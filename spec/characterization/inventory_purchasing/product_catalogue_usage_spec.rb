require "rails_helper"

# Characterization (Pilot 7 — Inventory & Purchasing Product Catalogue, M1) —
# CURRENT behaviour of how products use the catalogue (brands, product
# categories): the selectors on the product forms, the product-list filters, the
# product pages, and the catalogue's routes and structure.
#
# Assigning another business's brand / category / parent to a product is refused
# — pinned by product_references_spec.rb and the Pilot 6 regression specs in
# spec/requests/security/ (product_brand_ / product_category_ /
# product_parent_business_scope_spec.rb, SEC-P6-4/5/6); not repeated here.
RSpec.describe "Characterization: product catalogue usage", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let(:manager)  { api_user_with(business, :view_inventory, :manage_inventory) }

  let!(:brand)             { business.brands.create!(name: "Own Brand") }
  let!(:category)          { business.product_categories.create!(name: "Own Category") }
  let!(:inactive_category) { business.product_categories.create!(name: "Retired Category", active: false) }
  let!(:foreign_brand)     { other.brands.create!(name: "Foreign Brand") }
  let!(:foreign_category)  { other.product_categories.create!(name: "Foreign Category") }

  def new_product(owner, sku, **refs)
    owner.products.create!(name: "Product #{sku}", sku: sku, initial_cost_price: 1, average_cost_price: 1, **refs)
  end

  def select_options(name)
    Nokogiri::HTML(response.body).css("select[name='#{name}'] option").map(&:text)
  end

  before { sign_in manager }

  describe "product form selectors" do
    it "new: own brands, and own ACTIVE categories only — never another business's" do
      get new_inventory_product_path

      expect(select_options("product[brand_id]")).to include("Own Brand")
      expect(select_options("product[brand_id]")).not_to include("Foreign Brand")
      expect(select_options("product[product_category_id]")).to include("Own Category")
      expect(select_options("product[product_category_id]")).not_to include("Retired Category", "Foreign Category")
    end

    it "edit: the product's own inactive category stays selectable (selected); other inactive ones do not appear" do
      business.product_categories.create!(name: "Another Retired", active: false)
      product = new_product(business, "P-1", product_category: inactive_category)
      get edit_inventory_product_path(product)

      options = select_options("product[product_category_id]")
      expect(options).to include("Own Category", "Retired Category")
      expect(options).not_to include("Another Retired", "Foreign Category")
      expect(Nokogiri::HTML(response.body).at_css("select[name='product[product_category_id]'] option[selected]").text)
        .to eq("Retired Category")
    end

    it "a product keeps its inactive category when edited without changing it" do
      product = new_product(business, "P-1", product_category: inactive_category)
      patch inventory_product_path(product), params: { product: { name: "Renamed", product_category_id: inactive_category.id } }

      expect(product.reload).to have_attributes(name: "Renamed", product_category: inactive_category)
    end

    it "the model itself does not refuse an inactive category (the filter is only on the selector)" do
      product = business.products.build(name: "X", sku: "X-1", initial_cost_price: 1, average_cost_price: 1,
                                        product_category: inactive_category)
      expect(product).to be_valid
    end
  end

  describe "product list filters" do
    let!(:branded)   { new_product(business, "P-1", brand: brand, product_category: category) }
    let!(:unbranded) { new_product(business, "P-2") }

    it "filter dropdowns offer own brands and own active categories only" do
      get inventory_products_path

      expect(select_options("brand_id")).to include("Own Brand")
      expect(select_options("brand_id")).not_to include("Foreign Brand")
      expect(select_options("category_id")).to include("Own Category")
      expect(select_options("category_id")).not_to include("Retired Category", "Foreign Category")
    end

    it "filtering by brand_id / category_id narrows the business's products" do
      get inventory_products_path(brand_id: brand.id)
      expect(response.body).to include("Product P-1")
      expect(response.body).not_to include("Product P-2")

      get inventory_products_path(category_id: category.id)
      expect(response.body).to include("Product P-1")
      expect(response.body).not_to include("Product P-2")
    end

    it "filtering by another business's brand or category shows none of that business's products" do
      new_product(other, "F-1", brand: foreign_brand, product_category: foreign_category)

      get inventory_products_path(brand_id: foreign_brand.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Product F-1", "Product P-1")

      get inventory_products_path(category_id: foreign_category.id)
      expect(response.body).not_to include("Product F-1", "Product P-1")
    end

    it "the list shows each product's brand name" do
      get inventory_products_path
      expect(response.body).to match(%r{Own Brand})
    end
  end

  describe "product page" do
    it "shows the brand and category names, an inactive category included, and a dash when absent" do
      product = new_product(business, "P-1", brand: brand, product_category: inactive_category)
      get inventory_product_path(product)
      expect(response.body).to include("Own Brand", "Retired Category")

      bare = new_product(business, "P-2")
      get inventory_product_path(bare)
      expect(response.body).to match(%r{#{I18n.t("inventory.products.brand")}</dt><dd>—</dd>})
      expect(response.body).to match(%r{#{I18n.t("inventory.products.category")}</dt><dd>—</dd>})
    end
  end

  describe "structure" do
    it "routes: index / new / create / edit / update / destroy for both, no show; reached from the settings hub" do
      actions = ->(controller) { Rails.application.routes.routes.filter_map { |r| r.defaults[:action] if r.defaults[:controller] == controller }.uniq }

      expect(actions.call("inventory/brands")).to match_array(%w[index create new edit update destroy])
      expect(actions.call("inventory/product_categories")).to match_array(%w[index create new edit update destroy])

      get inventory_settings_path
      expect(response.body).to include(inventory_product_categories_path, inventory_brands_path)
    end

    it "products reference both optionally; a product with neither is valid" do
      expect(Product.reflect_on_association(:brand).options).to include(optional: true)
      expect(Product.reflect_on_association(:product_category).options).to include(optional: true)
      expect(Product.reflect_on_association(:brand).klass).to equal(Brand)
      expect(Product.reflect_on_association(:product_category).klass).to equal(ProductCategory)
      expect(new_product(business, "P-1")).to have_attributes(brand: nil, product_category: nil)
    end

    it "Brand and ProductCategory are plain records: only business / products associations and no own callbacks" do
      association_generated = /\A(autosave_associated_records_for_|around_save_collection_association)/
      [ Brand, ProductCategory ].each do |model|
        expect(model.reflect_on_all_associations.map(&:name)).to contain_exactly(:business, :products)
        %i[save create update destroy commit].each do |kind|
          own = model.__callbacks[kind].map(&:filter).grep(Symbol).grep_v(association_generated)
          expect(own).to be_empty, "#{model} #{kind}: #{own.inspect}"
        end
      end
    end

    it "both are top-level constants and tables in app/models/inventory_purchasing/ (moved in M7)" do
      expect(Object.const_source_location("Brand").first).to eq(Rails.root.join("app/models/inventory_purchasing/brand.rb").to_s)
      expect(Object.const_source_location("ProductCategory").first).to eq(Rails.root.join("app/models/inventory_purchasing/product_category.rb").to_s)
      expect([ Brand.table_name, ProductCategory.table_name ]).to eq(%w[brands product_categories])
    end
  end
end
