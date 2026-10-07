require "rails_helper"

# SEC-P6-4 (found in Pilot 6 — Inventory & Purchasing Supplier, M1): a
# product's brand_id accepted another business's brand — on create and update —
# whose name then showed on the product, and which its owner could no longer
# delete (Brand has_many :products, restrict_with_error). Product now validates
# that its brand belongs to the product's business.
RSpec.describe "Security: product brand business isolation", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let(:manager)  { api_user_with(business, :view_inventory, :manage_inventory) }
  let!(:brand)         { business.brands.create!(name: "Own Brand") }
  let!(:foreign_brand) { other.brands.create!(name: "Foreign Brand Secret") }

  before { sign_in manager }

  it "refuses creating a product with another business's brand (422, nothing saved)" do
    expect do
      post inventory_products_path, params: { product: { name: "P", sku: "P-1", initial_cost_price: 1, brand_id: foreign_brand.id } }
    end.not_to change(Product, :count)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(foreign_brand.products).to be_empty
    expect(foreign_brand.destroy).to be_truthy # still deletable by its owner
  end

  it "refuses changing a product's brand to another business's brand" do
    product = business.products.create!(name: "P", sku: "P-2", initial_cost_price: 1, average_cost_price: 1, brand: brand)

    patch inventory_product_path(product), params: { product: { brand_id: foreign_brand.id } }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(product.reload.brand).to eq(brand)
    expect(response.body).not_to include("Foreign Brand Secret")
  end

  it "still accepts the business's own brand, and no brand" do
    post inventory_products_path, params: { product: { name: "P", sku: "P-3", initial_cost_price: 1, brand_id: brand.id } }
    post inventory_products_path, params: { product: { name: "P", sku: "P-4", initial_cost_price: 1, brand_id: "" } }

    expect(business.products.find_by!(sku: "P-3").brand).to eq(brand)
    expect(business.products.find_by!(sku: "P-4").brand).to be_nil
  end

  it "the model refuses a foreign brand on every write path" do
    product = business.products.build(name: "X", sku: "X-1", initial_cost_price: 1, average_cost_price: 1, brand: foreign_brand)

    expect(product).not_to be_valid
    expect(product.errors[:brand]).to be_present
  end
end
