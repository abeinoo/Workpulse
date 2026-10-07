require "rails_helper"

# Characterization (Pilot 6 — Inventory & Purchasing Supplier, M1) — CURRENT
# behaviour of a product's references to other business-owned records.
#
# Every reference is now confined to the product's business. Found in M1 and
# fixed by their own commits (regression specs in spec/requests/security/):
# SEC-P6-4 brand (product_brand_business_scope_spec), SEC-P6-5 category
# (product_category_business_scope_spec), SEC-P6-6 parent product — which used
# to write into the other business's product (product_parent_business_scope_spec).
# The default supplier: SEC-P6-2 (product_default_supplier_business_scope_spec).
RSpec.describe "Characterization: product references to business-owned records", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let(:manager)  { api_user_with(business, :view_inventory, :manage_inventory) }

  let!(:brand)            { business.brands.create!(name: "Own Brand") }
  let!(:category)         { business.product_categories.create!(name: "Own Category") }
  let!(:parent)           { business.products.create!(name: "Own Parent", sku: "OP-1", initial_cost_price: 1, average_cost_price: 1) }
  let!(:foreign_brand)    { other.brands.create!(name: "Foreign Brand") }
  let!(:foreign_category) { other.product_categories.create!(name: "Foreign Category") }
  let!(:foreign_parent)   { other.products.create!(name: "Foreign Parent", sku: "FP-1", initial_cost_price: 1, average_cost_price: 1) }

  def create_product(sku, **refs)
    post inventory_products_path, params: { product: { name: "Child #{sku}", sku: sku, initial_cost_price: 1, **refs } }
    business.products.find_by(sku: sku)
  end

  before { sign_in manager }

  describe "same-business references are accepted" do
    it "brand, category and parent product of the same business" do
      product = create_product("C-1", brand_id: brand.id, product_category_id: category.id, parent_product_id: parent.id)

      expect(product).to have_attributes(brand: brand, product_category: category, parent_product: parent)
      expect(parent.reload).to have_attributes(track_inventory: false, receive_low_stock_notification: false)
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

  describe "SEC-P6-6 (fixed): another business's product is refused as the parent — no cross-business write" do
    it "on create: 422, nothing saved, the foreign product untouched (tracking on, no child)" do
      before_attack = foreign_parent.reload.attributes

      expect(create_product("V-1", parent_product_id: foreign_parent.id)).to be_nil
      expect(response).to have_http_status(:unprocessable_entity)
      expect(foreign_parent.reload.attributes).to eq(before_attack)
      expect(foreign_parent).to have_attributes(track_inventory: true, receive_low_stock_notification: true)
      expect(foreign_parent.child_products).to be_empty
    end

    it "on update: 422, the product keeps no parent, the foreign product untouched" do
      product = business.products.create!(name: "P", sku: "V-2", initial_cost_price: 1, average_cost_price: 1)
      before_attack = foreign_parent.reload.attributes
      patch inventory_product_path(product), params: { product: { parent_product_id: foreign_parent.id } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(product.reload.parent_product).to be_nil
      expect(foreign_parent.reload.attributes).to eq(before_attack)
    end
  end

  describe "already isolated" do
    it "a warehouse setting for another business's warehouse is refused (422)" do
      foreign_wh = other.warehouses.create!(name: "Foreign WH")

      expect do
        post inventory_products_path, params: { product: { name: "W", sku: "W-1", initial_cost_price: 1,
                                                           product_warehouse_settings_attributes: { "0" => { warehouse_id: foreign_wh.id, low_stock_level: 3 } } } }
      end.not_to change(Product, :count)
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
