require "rails_helper"

# Characterization (Pilot 6 — Inventory & Purchasing Supplier, M1) — CURRENT
# behaviour of a product's references to other business-owned records.
#
# Every reference is now confined to the product's business. Found in M1 and
# fixed by their own commits (regression specs in spec/requests/security/):
# SEC-P6-4 brand (product_brand_business_scope_spec), SEC-P6-5 category
# (product_category_business_scope_spec), SEC-P6-6 parent product — which used
# to write into the other business's product (moot: Product Family was removed;
# a crafted parent id is ignored).
# The default supplier: SEC-P6-2 (product_default_supplier_business_scope_spec).
RSpec.describe "Characterization: product references to business-owned records", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let(:manager)  { api_user_with(business, :view_inventory, :manage_inventory) }

  let!(:brand)            { business.brands.create!(name: "Own Brand") }
  let!(:category)         { business.product_categories.create!(name: "Own Category") }
  let!(:foreign_brand)    { other.brands.create!(name: "Foreign Brand") }
  let!(:foreign_category) { other.product_categories.create!(name: "Foreign Category") }
  let!(:foreign_parent)   { other.products.create!(name: "Foreign Parent", sku: "FP-1", initial_cost_price: 1, average_cost_price: 1) }

  def create_product(sku, **refs)
    post inventory_products_path, params: { product: { name: "Child #{sku}", sku: sku, initial_cost_price: 1, **refs } }
    business.products.find_by(sku: sku)
  end

  before { sign_in manager }

  describe "same-business references are accepted" do
    it "brand and category of the same business" do
      product = create_product("C-1", brand_id: brand.id, product_category_id: category.id)

      expect(product).to have_attributes(brand: brand, product_category: category)
    end
  end

  describe "SEC-P6-4 (fixed): another business's brand is refused" do
    it "on create: 422, nothing saved, the brand stays deletable by its owner" do
      expect(create_product("B-1", brand_id: foreign_brand.id)).to be_nil
      expect(response).to have_http_status(:unprocessable_entity)
      expect(foreign_brand.destroy).to be_truthy
    end

    it "on update: 422, the product keeps its brand" do
      product = business.products.create!(name: "P", sku: "B-2", initial_cost_price: 1, average_cost_price: 1, brand: brand)
      patch inventory_product_path(product), params: { product: { brand_id: foreign_brand.id } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(product.reload.brand).to eq(brand)
    end
  end

  describe "SEC-P6-5 (fixed): another business's product category is refused" do
    it "on create: 422, nothing saved, the category stays deletable by its owner" do
      expect(create_product("K-1", product_category_id: foreign_category.id)).to be_nil
      expect(response).to have_http_status(:unprocessable_entity)
      expect(foreign_category.destroy).to be_truthy
    end

    it "on update: 422, the product keeps no category" do
      product = business.products.create!(name: "P", sku: "K-2", initial_cost_price: 1, average_cost_price: 1)
      patch inventory_product_path(product), params: { product: { product_category_id: foreign_category.id } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(product.reload.product_category).to be_nil
    end
  end

  # SEC-P6-6 is moot since Product Family was removed: there is no parent
  # reference any more. A crafted parent_product_id is ignored — nothing is
  # linked and the other business's product is never written.
  describe "SEC-P6-6: a crafted parent product id is ignored — no cross-business write" do
    it "on create: saved without any parent, the foreign product untouched" do
      before_attack = foreign_parent.reload.attributes

      product = create_product("V-1", parent_product_id: foreign_parent.id)
      expect(product).to be_present
      expect(raw_parent_product_id(product)).to be_nil
      expect(foreign_parent.reload.attributes).to eq(before_attack)
    end

    it "on update: the product keeps no parent, the foreign product untouched" do
      product = business.products.create!(name: "P", sku: "V-2", initial_cost_price: 1, average_cost_price: 1)
      before_attack = foreign_parent.reload.attributes
      patch inventory_product_path(product), params: { product: { parent_product_id: foreign_parent.id } }

      expect(response).to redirect_to(inventory_product_path(product))
      expect(raw_parent_product_id(product)).to be_nil
      expect(foreign_parent.reload.attributes).to eq(before_attack)
    end
  end

  describe "already isolated" do
    # Was refused by the model validation (422). Since the product-warehouse
    # settings scope guard (product_warehouse_settings_scope_spec) it is refused
    # earlier, as not authorized, before any attribute is assigned.
    it "a warehouse setting for another business's warehouse is refused (not authorized)" do
      foreign_wh = other.warehouses.create!(name: "Foreign WH")

      expect do
        post inventory_products_path, params: { product: { name: "W", sku: "W-1", initial_cost_price: 1,
                                                           product_warehouse_settings_attributes: { "0" => { warehouse_id: foreign_wh.id, low_stock_level: 3 } } } }
      end.not_to change { [ Product.count, ProductWarehouseSetting.count ] }
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
    end
  end
end
