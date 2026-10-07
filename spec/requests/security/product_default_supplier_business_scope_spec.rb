require "rails_helper"

# SEC-P6-2 (found in Pilot 6 — Inventory & Purchasing Supplier, M0): a
# product's default_supplier_id accepted another business's supplier. The
# product page then showed the foreign supplier's name, and the victim's
# supplier could no longer be deleted (foreign-key error). Product now
# validates that its default supplier belongs to the product's business.
RSpec.describe "Security: product default supplier business isolation", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let(:manager)  { api_user_with(business, :view_inventory, :manage_inventory) }
  let!(:supplier)         { business.suppliers.create!(name: "Own Supplier") }
  let!(:foreign_supplier) { other.suppliers.create!(name: "Foreign Supplier Secret") }

  def product_params(default_supplier_id, sku: "P-1")
    { product: { name: "Conditioner", sku: sku, initial_cost_price: 3, default_supplier_id: default_supplier_id } }
  end

  before { sign_in manager }

  it "refuses creating a product with another business's default supplier (422, nothing saved)" do
    expect { post inventory_products_path, params: product_params(foreign_supplier.id) }.not_to change(Product, :count)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(Product.where(default_supplier_id: foreign_supplier.id)).to be_empty
  end

  it "refuses changing a product's default supplier to another business's supplier" do
    product = business.products.create!(name: "Dye", sku: "DY-1", initial_cost_price: 1, average_cost_price: 1,
                                        default_supplier: supplier)

    patch inventory_product_path(product), params: { product: { default_supplier_id: foreign_supplier.id } }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(product.reload.default_supplier_id).to eq(supplier.id)
    expect(response.body).not_to include("Foreign Supplier Secret")
  end

  it "still stores the business's own supplier as the default" do
    post inventory_products_path, params: product_params(supplier.id)

    expect(business.products.find_by!(sku: "P-1").default_supplier).to eq(supplier)
  end

  it "still allows no default supplier (blank or omitted)" do
    post inventory_products_path, params: product_params("")
    post inventory_products_path, params: { product: { name: "Bare", sku: "P-2", initial_cost_price: 1 } }

    expect(business.products.where(sku: %w[P-1 P-2]).pluck(:default_supplier_id)).to eq([ nil, nil ])
  end

  it "the model refuses a foreign default supplier on every write path" do
    product = business.products.build(name: "X", sku: "X-1", initial_cost_price: 1, average_cost_price: 1,
                                      default_supplier: foreign_supplier)

    expect(product).not_to be_valid
    expect(product.errors[:default_supplier]).to be_present
  end
end
