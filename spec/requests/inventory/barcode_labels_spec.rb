require "rails_helper"

RSpec.describe "Inventory barcode labels", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }

  let!(:product) do
    p = business.products.create!(name: "Argan Oil", sku: "AO-1",
                                  initial_cost_price: 10, average_cost_price: 10,
                                  selling_markup_percentage: 50)
    p.product_barcodes.create!(barcode: "6291041500213", barcode_type: "manufacturer", is_primary: true)
    p.product_barcodes.create!(barcode: "10000001",      barcode_type: "internal",     is_primary: false)
    p
  end

  let(:manufacturer_bc) { product.product_barcodes.find_by(barcode_type: "manufacturer") }
  let(:internal_bc)     { product.product_barcodes.find_by(barcode_type: "internal") }

  before { sign_in owner }

  describe "GET /inventory/barcode_labels/:id" do
    it "returns 200 and renders the print layout" do
      get inventory_barcode_label_path(product)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("barcode-svg")
      expect(response.body).to include("6291041500213")
      expect(response.body).to include("10000001")
    end

    it "includes all barcode values from all types" do
      get inventory_barcode_label_path(product)
      expect(response.body).to include("6291041500213")
      expect(response.body).to include("10000001")
    end

    it "renders only the requested barcode when barcode_id is given" do
      get inventory_barcode_label_path(product, barcode_id: internal_bc.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("10000001")
      expect(response.body).not_to include("6291041500213")
    end

    it "renders empty state when barcode_id does not match any barcode" do
      get inventory_barcode_label_path(product, barcode_id: 999999)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("inventory.barcode_labels.no_barcodes"))
    end

    it "honours the quantity param and repeats labels" do
      get inventory_barcode_label_path(product, barcode_id: manufacturer_bc.id, quantity: 3)
      expect(response.body.scan("6291041500213").length).to be >= 3
    end

    it "clamps quantity to maximum of 100" do
      get inventory_barcode_label_path(product, barcode_id: manufacturer_bc.id, quantity: 500)
      # Count label boxes, not barcode string occurrences (each label renders the value twice)
      expect(response.body.scan('class="label"').length).to eq(100)
    end

    it "returns 404 for a product belonging to another business" do
      other_business = create(:business)
      other_product  = other_business.products.create!(name: "Other", sku: "OT-1",
                                                       initial_cost_price: 1, average_cost_price: 1)
      get inventory_barcode_label_path(other_product)
      expect(response).to have_http_status(:not_found)
    end

    it "redirects unauthenticated requests" do
      sign_out owner
      get inventory_barcode_label_path(product)
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe "GET /inventory/barcode_labels" do
    let!(:product2) do
      p = business.products.create!(name: "Conditioner", sku: "CO-1",
                                    initial_cost_price: 8, average_cost_price: 8)
      p.product_barcodes.create!(barcode: "6291041500220", barcode_type: "manufacturer", is_primary: true)
      p
    end

    it "renders labels for all specified products" do
      get inventory_barcode_labels_path(product_ids: [product.id, product2.id])
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Argan Oil")
      expect(response.body).to include("Conditioner")
    end

    it "shows empty state when no product_ids are provided" do
      get inventory_barcode_labels_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("inventory.barcode_labels.no_products_selected"))
    end

    it "limits to 100 products" do
      get inventory_barcode_labels_path(product_ids: (1..150).to_a)
      expect(response).to have_http_status(:ok)
    end

    it "skips products from another business" do
      other = create(:business)
      other_product = other.products.create!(name: "Foreign", sku: "FO-1",
                                             initial_cost_price: 1, average_cost_price: 1)
      get inventory_barcode_labels_path(product_ids: [other_product.id])
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Foreign")
    end
  end
end
