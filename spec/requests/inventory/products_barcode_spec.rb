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

  # Generating a barcode on the product form never writes: the code fills an
  # ordinary unsaved row, inserted (or discarded) with the product's Save. The
  # former immediate-save endpoint (generate_barcode) left a barcode behind
  # when its row was removed before saving — it no longer exists.
  describe "generating never writes before Save" do
    it "asking for the next code creates no barcode" do
      expect { get next_barcode_code_inventory_products_path, as: :json }.not_to change(ProductBarcode, :count)
    end

    it "the immediate-save endpoint is gone" do
      expect { Rails.application.routes.recognize_path("/inventory/products/#{product.id}/generate_barcode", method: :post) }
        .to raise_error(ActionController::RoutingError)
    end
  end
end
