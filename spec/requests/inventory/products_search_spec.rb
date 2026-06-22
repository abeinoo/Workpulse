require "rails_helper"

RSpec.describe "Inventory::ProductsController#index search", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }

  let!(:apple) do
    business.products.create!(name: "Apple Juice", sku: "AJ-1",
                               initial_cost_price: 5, average_cost_price: 5)
  end
  let!(:banana) do
    business.products.create!(name: "Banana Shake", sku: "BS-9",
                               initial_cost_price: 4, average_cost_price: 4)
  end
  let!(:cherry) do
    p = business.products.create!(name: "Cherry Soda", sku: "CS-2",
                                   initial_cost_price: 3, average_cost_price: 3)
    p.product_barcodes.create!(barcode: "6291041500213", barcode_type: "manufacturer", is_primary: true)
    p
  end

  before { sign_in owner }

  describe "GET /inventory/products?q=" do
    it "returns 200 without a search term" do
      get inventory_products_path
      expect(response).to have_http_status(:ok)
    end

    it "filters by product name" do
      get inventory_products_path, params: { q: "apple" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Apple Juice")
      expect(response.body).not_to include("Banana Shake")
    end

    it "filters by SKU" do
      get inventory_products_path, params: { q: "BS-9" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Banana Shake")
      expect(response.body).not_to include("Apple Juice")
    end

    it "filters by barcode" do
      get inventory_products_path, params: { q: "629104" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Cherry Soda")
      expect(response.body).not_to include("Apple Juice")
    end

    # Regression: PG::InvalidColumnReference when DISTINCT + ORDER BY name
    # were combined while only selecting id.
    it "does not raise a PostgreSQL DISTINCT/ORDER BY error" do
      expect {
        get inventory_products_path, params: { q: "a" }
      }.not_to raise_error
      expect(response).to have_http_status(:ok)
    end

    it "returns no duplicate IDs when a product matches both name and barcode" do
      # cherry matches on barcode AND on its name if we search a term in both;
      # all_ids.uniq must deduplicate so the product appears only once in the scope.
      cherry.update!(name: "Cherry 629104")
      get inventory_products_path, params: { q: "629104" }
      expect(response).to have_http_status(:ok)
      # The product_id data attribute is the reliable single-occurrence anchor.
      expect(response.body.scan("data-product-id=\"#{cherry.id}\"").length).to eq(1)
    end
  end
end
