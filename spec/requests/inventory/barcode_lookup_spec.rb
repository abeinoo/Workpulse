require "rails_helper"

RSpec.describe "Inventory barcode lookup", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }
  let!(:product) do
    p = business.products.create!(name: "Shampoo", sku: "SH-1",
                                  initial_cost_price: 2, average_cost_price: 2)
    p.product_barcodes.create!(barcode: "6291041500213", is_primary: true)
    p
  end

  before { sign_in owner }

  it "resolves a product by exact barcode" do
    get inventory_barcode_lookup_path(code: "6291041500213")
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["id"]).to eq(product.id)
    expect(body["matched_on"]).to eq("barcode")
    expect(body["barcodes"]).to include("6291041500213")
  end

  it "falls back to SKU when no barcode matches" do
    get inventory_barcode_lookup_path(code: "sh-1")
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["matched_on"]).to eq("sku")
  end

  it "returns 404 for an unknown code" do
    get inventory_barcode_lookup_path(code: "0000000000000")
    expect(response).to have_http_status(:not_found)
  end

  it "does not resolve a product from another business" do
    other = create(:business)
    other_product = other.products.create!(name: "Other", sku: "OT-1",
                                           initial_cost_price: 1, average_cost_price: 1)
    other_product.product_barcodes.create!(barcode: "111", is_primary: true)
    get inventory_barcode_lookup_path(code: "111")
    expect(response).to have_http_status(:not_found)
  end
end
