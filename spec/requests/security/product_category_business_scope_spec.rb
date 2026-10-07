require "rails_helper"

# SEC-P6-5 (found in Pilot 6 — Inventory & Purchasing Supplier, M1): a
# product's product_category_id accepted another business's category — on
# create and update — whose name then showed on the product, and which its owner
# could no longer delete (ProductCategory has_many :products,
# restrict_with_error). Product now validates that its category belongs to the
# product's business.
RSpec.describe "Security: product category business isolation", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let(:manager)  { api_user_with(business, :view_inventory, :manage_inventory) }
  let!(:category)         { business.product_categories.create!(name: "Own Category") }
  let!(:foreign_category) { other.product_categories.create!(name: "Foreign Category Secret") }

  before { sign_in manager }

  it "refuses creating a product in another business's category (422, nothing saved)" do
    expect do
      post inventory_products_path,
           params: { product: { name: "P", sku: "P-1", initial_cost_price: 1, product_category_id: foreign_category.id } }
    end.not_to change(Product, :count)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(foreign_category.products).to be_empty
    expect(foreign_category.destroy).to be_truthy # still deletable by its owner
  end

  it "refuses moving a product to another business's category" do
    product = business.products.create!(name: "P", sku: "P-2", initial_cost_price: 1, average_cost_price: 1,
                                        product_category: category)

    patch inventory_product_path(product), params: { product: { product_category_id: foreign_category.id } }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(product.reload.product_category).to eq(category)
    expect(response.body).not_to include("Foreign Category Secret")
  end

  it "still accepts the business's own category, and no category" do
    post inventory_products_path, params: { product: { name: "P", sku: "P-3", initial_cost_price: 1, product_category_id: category.id } }
    post inventory_products_path, params: { product: { name: "P", sku: "P-4", initial_cost_price: 1, product_category_id: "" } }

    expect(business.products.find_by!(sku: "P-3").product_category).to eq(category)
    expect(business.products.find_by!(sku: "P-4").product_category).to be_nil
  end

  it "the model refuses a foreign category on every write path" do
    product = business.products.build(name: "X", sku: "X-1", initial_cost_price: 1, average_cost_price: 1,
                                      product_category: foreign_category)

    expect(product).not_to be_valid
    expect(product.errors[:product_category]).to be_present
  end
end
