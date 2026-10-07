require "rails_helper"

# Pilot 7 — Inventory & Purchasing Product Catalogue (M7): Brand and
# ProductCategory live physically in Inventory & Purchasing
# (app/models/inventory_purchasing/, the collapsed directory from
# config/initializers/inventory_purchasing_autoload.rb) but keep their top-level
# constants, tables and associations. Guards against an accidental un-collapse,
# namespace, table or association change.
RSpec.describe "Architecture: Inventory & Purchasing product catalogue model location" do
  { "Brand" => "brands", "ProductCategory" => "product_categories" }.each do |name, table|
    file = "#{name.underscore}.rb"

    describe name do
      it "loads as a top-level constant from app/models/inventory_purchasing/" do
        expect(name.constantize.name).to eq(name) # resolving the constant also triggers the autoload
        path = Object.const_source_location(name).first
        expect(path).to eq(Rails.root.join("app/models/inventory_purchasing", file).to_s)
        expect(File.dirname(path)).to eq(Rails.root.join("app/models/inventory_purchasing").to_s)
      end

      it "no longer has a top-level model file" do
        expect(File).not_to exist(Rails.root.join("app/models", file))
      end

      it "keeps #{table} as its table" do
        expect(name.constantize.table_name).to eq(table)
      end

      it "is not namespaced under InventoryPurchasing, and leaves the Inventory:: namespace alone" do
        expect(defined?(::InventoryPurchasing)).to be_nil.or(satisfy { !::InventoryPurchasing.const_defined?(name, false) })
        expect(Inventory.const_defined?(name, false)).to be(false)
      end
    end
  end

  it "keeps the controllers in the Inventory:: namespace" do
    expect(Inventory::BrandsController.name).to eq("Inventory::BrandsController")
    expect(Inventory::ProductCategoriesController.name).to eq("Inventory::ProductCategoriesController")
  end

  it "resolves the same classes from every association" do
    expect(Brand.reflect_on_association(:business).klass).to equal(Business)
    expect(Brand.reflect_on_association(:products).klass).to equal(Product)
    expect(ProductCategory.reflect_on_association(:business).klass).to equal(Business)
    expect(ProductCategory.reflect_on_association(:products).klass).to equal(Product)
    expect(Business.reflect_on_association(:brands).klass).to equal(Brand)
    expect(Business.reflect_on_association(:product_categories).klass).to equal(ProductCategory)
    expect(Product.reflect_on_association(:brand).klass).to equal(Brand)
    expect(Product.reflect_on_association(:product_category).klass).to equal(ProductCategory)
  end

  it "keeps its behaviour: business scoping, validations, the active scope and the restrict on products" do
    business = create(:business)
    brand    = business.brands.create!(name: "Acme")
    category = business.product_categories.create!(name: "Cleaning")
    business.product_categories.create!(name: "Retired", active: false)

    expect(Brand.for_business(business)).to contain_exactly(brand)
    expect(ProductCategory.for_business(business).active).to contain_exactly(category)
    expect(business.brands.build(name: "ACME")).not_to be_valid
    expect(business.product_categories.build(name: "")).not_to be_valid
    [ Brand, ProductCategory ].each do |model|
      expect(model.reflect_on_association(:products).options).to include(dependent: :restrict_with_error)
    end
  end
end
