require "rails_helper"

# Characterization (Pilot 7 — Inventory & Purchasing Product Catalogue, M1) —
# CURRENT behaviour of how the product CSV import
# (Inventory::Imports::ProductImporter, POST /inventory/products/import) resolves
# the Brand and Category columns. Parsing, SKU / barcode duplicates and opening
# balances are covered by spec/services/inventory/imports/product_importer_spec.rb.
#
# P7-D1 (known defect, pinned, not fixed): names are looked up case-SENSITIVELY
# (find_or_create_by!(name:)) while brand and category names are unique
# case-INSENSITIVELY. A name that differs only in case from an existing one
# (or from an earlier row of the same file) fails the create with
# ActiveRecord::RecordInvalid, which neither the importer nor the controller
# rescues: the whole import is rolled back and Rails' exception handling maps
# the error to 422 — production shows the generic public/422.html page, with no
# import result and no row-level message.
RSpec.describe "Characterization: product import catalogue resolution", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let(:manager)  { api_user_with(business, :view_inventory, :manage_inventory) }

  let!(:foreign_brand)    { other.brands.create!(name: "Foreign Brand") }
  let!(:foreign_category) { other.product_categories.create!(name: "Foreign Category") }

  def csv(*rows)
    CSV.generate do |out|
      out << [ "Product Name", "SKU", "Brand", "Category" ]
      rows.each { |row| out << row }
    end
  end

  def import(data) = Inventory::Imports::ProductImporter.new(business, data).call

  def upload(data)
    Rack::Test::UploadedFile.new(StringIO.new(data), "text/csv", original_filename: "products.csv")
  end

  describe "brand resolution" do
    it "reuses an existing brand of the business when the name matches exactly (surrounding spaces stripped)" do
      brand = business.brands.create!(name: "Acme")

      expect { import(csv([ "Widget", "W-1", "  Acme ", "" ])) }.not_to change(Brand, :count)
      expect(business.products.find_by!(sku: "W-1").brand).to eq(brand)
    end

    it "creates a missing brand in the importing business, once for repeated rows" do
      expect { import(csv([ "Widget", "W-1", "Nova", "" ], [ "Gadget", "W-2", "Nova", "" ])) }
        .to change(business.brands, :count).by(1)

      nova = business.brands.find_by!(name: "Nova")
      expect(business.products.where(sku: %w[W-1 W-2]).map(&:brand)).to all(eq(nova))
    end

    it "never reuses another business's brand of the same name: a new one is created in the importing business" do
      expect { import(csv([ "Widget", "W-1", "Foreign Brand", "" ])) }.to change(business.brands, :count).by(1)

      brand = business.products.find_by!(sku: "W-1").brand
      expect(brand).not_to eq(foreign_brand)
      expect(brand.business_id).to eq(business.id)
      expect(foreign_brand.reload.products).to be_empty
    end

    it "a blank brand leaves the product without one" do
      import(csv([ "Widget", "W-1", "", "" ]))
      expect(business.products.find_by!(sku: "W-1").brand).to be_nil
    end
  end

  describe "category resolution" do
    it "reuses an existing category of the business when the name matches exactly" do
      category = business.product_categories.create!(name: "Cleaning")

      expect { import(csv([ "Widget", "W-1", "", "Cleaning" ])) }.not_to change(ProductCategory, :count)
      expect(business.products.find_by!(sku: "W-1").product_category).to eq(category)
    end

    it "reuses an existing INACTIVE category as is (it stays inactive)" do
      retired = business.product_categories.create!(name: "Retired", active: false)

      import(csv([ "Widget", "W-1", "", "Retired" ]))
      expect(business.products.find_by!(sku: "W-1").product_category).to eq(retired)
      expect(retired.reload.active).to be(false)
    end

    it "creates a missing category (active, no description) in the importing business" do
      expect { import(csv([ "Widget", "W-1", "", "Cleaning" ])) }.to change(business.product_categories, :count).by(1)
      expect(business.product_categories.find_by!(name: "Cleaning")).to have_attributes(active: true, description: nil)
    end

    it "never reuses another business's category of the same name" do
      import(csv([ "Widget", "W-1", "", "Foreign Category" ]))

      category = business.products.find_by!(sku: "W-1").product_category
      expect(category).not_to eq(foreign_category)
      expect(category.business_id).to eq(business.id)
      expect(foreign_category.reload.products).to be_empty
    end
  end

  describe "P7-D1 (known defect, pinned): case-sensitive lookup vs case-insensitive uniqueness" do
    it "an existing brand 'Acme' and a row with 'acme': RecordInvalid, the whole import rolled back" do
      business.brands.create!(name: "Acme")

      expect { import(csv([ "Good", "OK-1", "Fine", "" ], [ "Widget", "W-1", "acme", "" ])) }
        .to raise_error(ActiveRecord::RecordInvalid, /Name has already been taken/)
      expect(business.products.where(sku: %w[OK-1 W-1])).to be_empty
      expect(business.brands.pluck(:name)).to eq([ "Acme" ])
    end

    it "one file with 'Acme' then 'acme' (no existing brand): the second row raises, nothing is kept" do
      expect { import(csv([ "Widget", "W-1", "Acme", "" ], [ "Gadget", "W-2", "acme", "" ])) }
        .to raise_error(ActiveRecord::RecordInvalid)
      expect(business.products).to be_empty
      expect(business.brands).to be_empty
    end

    it "the same for categories: existing 'Cleaning', row 'CLEANING'" do
      business.product_categories.create!(name: "Cleaning")

      expect { import(csv([ "Widget", "W-1", "", "CLEANING" ])) }.to raise_error(ActiveRecord::RecordInvalid)
      expect(business.products).to be_empty
    end

    it "another business's 'acme' plays no part: the importing business's own lookup decides" do
      other.brands.create!(name: "acme")

      expect { import(csv([ "Widget", "W-1", "Acme", "" ])) }.to change(business.brands, :count).by(1)
    end

    it "through the import screen the error is not rescued: Rails' generic 422 error page, nothing saved" do
      business.brands.create!(name: "Acme")
      sign_in manager

      post run_import_inventory_products_path, params: { file: upload(csv([ "Good", "OK-1", "Fine", "" ], [ "Widget", "W-1", "acme", "" ])) }

      expect(ActionDispatch::ExceptionWrapper.rescue_responses["ActiveRecord::RecordInvalid"]).to eq(:unprocessable_content)
      expect(response).to have_http_status(422)
      expect(response.body).to include("ActiveRecord::RecordInvalid") # the test environment's exception page
      expect(business.products).to be_empty
      expect(business.brands.pluck(:name)).to eq([ "Acme" ])
    end
  end

  describe "through the import screen" do
    before { sign_in manager }

    it "resolves catalogue names inside the signed-in user's business" do
      own = business.brands.create!(name: "Acme")
      post run_import_inventory_products_path,
           params: { file: upload(csv([ "Widget", "W-1", "Acme", "Foreign Category" ])) }

      expect(response).to have_http_status(:ok)
      product = business.products.find_by!(sku: "W-1")
      expect(product.brand).to eq(own)
      expect(product.product_category.business_id).to eq(business.id)
      expect(other.products).to be_empty
    end

    it "a view_inventory-only user cannot import (Product#create? refused), nothing created" do
      sign_in api_user_with(business, :view_inventory)

      expect { post run_import_inventory_products_path, params: { file: upload(csv([ "Widget", "W-1", "Nova", "Cat" ])) } }
        .not_to change(Brand, :count)
      expect(response).to redirect_to(root_path)
      expect(ProductCategory.where(name: "Cat")).to be_empty
    end
  end
end
