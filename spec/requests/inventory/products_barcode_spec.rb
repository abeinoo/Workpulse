require "rails_helper"

RSpec.describe "Inventory products barcode endpoints", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }
  let!(:product) do
    business.products.create!(name: "Serum", sku: "SR-1",
                               initial_cost_price: 20, average_cost_price: 20)
  end

  before { sign_in owner }

  describe "GET /inventory/products/next_barcode_code" do
    it "returns the next available internal barcode code as JSON" do
      get next_barcode_code_inventory_products_path, as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["code"]).to eq("10000001")
    end

    it "increments when internal barcodes already exist" do
      product.product_barcodes.create!(barcode: "10000003", barcode_type: "internal", is_primary: true)
      get next_barcode_code_inventory_products_path, as: :json
      expect(JSON.parse(response.body)["code"]).to eq("10000004")
    end

    it "requires authentication" do
      sign_out owner
      get next_barcode_code_inventory_products_path, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "POST /inventory/products/:id/generate_barcode" do
    it "creates and returns an internal barcode" do
      post generate_barcode_inventory_product_path(product), as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["barcode"]).to eq("10000001")
      expect(body["barcode_type"]).to eq("internal")
      expect(body["id"]).to be_present
    end

    it "saves the barcode to the database" do
      expect {
        post generate_barcode_inventory_product_path(product), as: :json
      }.to change { product.product_barcodes.where(barcode_type: "internal").count }.by(1)
    end

    it "marks the barcode as primary when the product has no primary barcode" do
      post generate_barcode_inventory_product_path(product), as: :json
      body = JSON.parse(response.body)
      expect(body["is_primary"]).to be true
      expect(product.product_barcodes.reload.where(is_primary: true).count).to eq(1)
    end

    it "does not make the new barcode primary when a primary already exists" do
      product.product_barcodes.create!(barcode: "6291041500213", barcode_type: "manufacturer", is_primary: true)
      post generate_barcode_inventory_product_path(product), as: :json
      body = JSON.parse(response.body)
      expect(body["is_primary"]).to be false
    end

    it "generates sequential codes on successive calls" do
      post generate_barcode_inventory_product_path(product), as: :json
      first_code = JSON.parse(response.body)["barcode"]

      post generate_barcode_inventory_product_path(product), as: :json
      second_code = JSON.parse(response.body)["barcode"]

      expect(second_code.to_i).to eq(first_code.to_i + 1)
    end

    it "returns 404 for a product from another business" do
      other = create(:business)
      other_product = other.products.create!(name: "Foreign", sku: "FO-1",
                                             initial_cost_price: 1, average_cost_price: 1)
      post generate_barcode_inventory_product_path(other_product), as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "requires authentication" do
      sign_out owner
      post generate_barcode_inventory_product_path(product), as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
