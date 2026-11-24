require "rails_helper"

# Every barcode of a product — primary or additional, any barcode type —
# resolves to that product wherever products are looked up or picked, within
# the user's business only; SKU and name searches keep working.
RSpec.describe "Product search by any barcode", type: :request do
  let(:business)  { create(:business) }
  let(:other)     { create(:business) }
  let!(:owner)    { create(:user, :owner, business: business) }
  let!(:warehouse) { business.warehouses.create!(name: "Main") }
  let!(:product) do
    business.products.create!(name: "Argan Oil", sku: "AO-1", initial_cost_price: 1, average_cost_price: 1).tap do |p|
      p.product_barcodes.create!(barcode: "0629104150021", barcode_type: "manufacturer", is_primary: true)
      p.product_barcodes.create!(barcode: "CARTON-77", barcode_type: "carton", is_primary: false)
      p.product_barcodes.create!(barcode: "10000042", barcode_type: "internal", is_primary: false)
    end
  end
  let!(:foreign) do
    other.products.create!(name: "Foreign Oil", sku: "FO-1", initial_cost_price: 1, average_cost_price: 1).tap do |p|
      p.product_barcodes.create!(barcode: "FOREIGN-1", barcode_type: "manufacturer", is_primary: true)
    end
  end

  let(:every_code) { [ "0629104150021", "CARTON-77", "10000042", " carton-77 ", " CARTON-77\t" ] }

  before { sign_in owner }

  def lookup(code) = (get inventory_barcode_lookup_path(code: code), as: :json) && response
  def picker_ids(q, kind: "transactable") = (get inventory_product_search_path(q: q, kind: kind), as: :json) && response.parsed_body.map { |p| p["id"] }

  describe "the scanner lookup (every document form's barcode scanner)" do
    it "resolves the primary and every additional barcode, trimmed and case-insensitively, to the product" do
      every_code.each do |code|
        expect(lookup(code)).to have_http_status(:ok), code.inspect
        expect(response.parsed_body).to include("id" => product.id, "matched_on" => "barcode")
        expect(response.parsed_body["barcodes"]).to contain_exactly("0629104150021", "CARTON-77", "10000042")
      end
    end

    it "keeps the leading zeros (no number conversion) and still finds by SKU" do
      expect(lookup("629104150021")).to have_http_status(:not_found)
      expect(lookup("ao-1").parsed_body).to include("id" => product.id, "matched_on" => "sku")
    end

    it "never resolves another business's barcode, or an archived product" do
      expect(lookup("FOREIGN-1")).to have_http_status(:not_found)
      product.update!(active: false, archived_at: Time.current)
      expect(lookup("CARTON-77")).to have_http_status(:not_found)
    end
  end

  describe "the searchable product pickers (document lines, requests, reports, branch comparison)" do
    it "find the product by any of its barcodes — every kind — and keep SKU / name search" do
      %w[transactable tracked all].each do |kind|
        every_code.each { |code| expect(picker_ids(code, kind: kind)).to eq([ product.id ]), "#{kind} #{code.inspect}" }
        expect(picker_ids("AO-1", kind: kind)).to eq([ product.id ])
        expect(picker_ids("argan", kind: kind)).to eq([ product.id ])
      end
    end

    it "never list another business's product by its barcode" do
      expect(picker_ids("FOREIGN-1", kind: "all")).to be_empty
    end
  end

  describe "the product list search" do
    it "finds the product by an additional barcode, never another business's" do
      get inventory_products_path(q: "carton-77")
      expect(response.body).to include("AO-1")
      get inventory_products_path(q: "FOREIGN-1")
      expect(response.body).not_to include("FO-1")
    end
  end

  describe "stocktaking (scan-to-count)" do
    it "every row carries all of its product's barcodes, loaded in bulk" do
      counter = user_with_stock_permissions(business, :view_inventory, :manage_stock_counts)
      count = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [])
      2.times { |i| business.products.create!(name: "Extra #{i}", sku: "EX-#{i}", initial_cost_price: 1, average_cost_price: 1) }
      sign_in counter

      barcode_queries = 0
      counter_fn = ->(*, payload) { barcode_queries += 1 if payload[:sql].include?("product_barcodes") && !payload[:cached] }
      ActiveSupport::Notifications.subscribed(counter_fn, "sql.active_record") { get edit_inventory_stock_count_path(count) }

      expect(response).to have_http_status(:ok)
      row = Nokogiri::HTML(response.body).at_css("tbody tr[data-product-id='#{product.id}']")
      expect(row["data-barcodes"].split("|")).to contain_exactly("0629104150021", "CARTON-77", "10000042")
      expect(barcode_queries).to be <= 2 # one bulk load, never one per row
    end
  end

  describe "goods receipts from a purchase request" do
    it "the request line's product option carries every barcode for local scan matching" do
      supplier = business.suppliers.create!(name: "Acme")
      pr = business.purchase_requests.create!(warehouse: warehouse, status: "approved", created_by: owner,
                                              items_attributes: [ { product_id: product.id, quantity: 2, unit_price: 1, supplier_id: supplier.id } ])
      get new_inventory_goods_receipt_path(purchase_request_id: pr.id)
      option = Nokogiri::HTML(response.body).css("option[value='#{product.id}']").find { |o| o["data-barcodes"].present? }
      expect(option["data-barcodes"].split("|")).to contain_exactly("0629104150021", "CARTON-77", "10000042")
    end
  end
end
