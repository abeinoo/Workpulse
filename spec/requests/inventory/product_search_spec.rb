require "rails_helper"

# GET /inventory/product_search — the server search behind every product
# picker (product-combobox): name / SKU / barcode, exact codes first, scoped by
# ProductPolicy (business isolation) and the picker's kind (the list it always
# offered), at most 20 rows, with the payload every line listener reads.
RSpec.describe "Inventory product search (pickers)", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }
  let(:supplier) { business.suppliers.create!(name: "Acme") }

  def product(name, sku, **attrs) = business.products.create!(name: name, sku: sku, **attrs)

  def search(**params)
    get inventory_product_search_path(**params)
    expect(response).to have_http_status(:ok)
    response.parsed_body
  end

  def names(**params) = search(**params).map { |p| p["name"] }

  before { sign_in owner }

  describe "matching" do
    let!(:shampoo) { product("Argan Shampoo", "SH-100") }
    let!(:mask)    { product("Hair Mask", "MK-200").tap { |p| p.product_barcodes.create!(barcode: "6281000012345", is_primary: true) } }
    let!(:serum)   { product("Serum SH-1", "SR-300") }

    it "by name, SKU and barcode — case-insensitive, partial" do
      expect(names(q: "argan")).to eq([ "Argan Shampoo" ])
      expect(names(q: "mk-2")).to eq([ "Hair Mask" ])
      expect(names(q: "62810000")).to eq([ "Hair Mask" ])
    end

    it "puts an exact SKU or barcode match first" do
      expect(names(q: "sh-100")).to eq([ "Argan Shampoo" ])
      expect(names(q: "SH-1")).to eq([ "Argan Shampoo", "Serum SH-1" ]) # partial matches, by name
      expect(names(q: "SR-300").first).to eq("Serum SH-1")
      expect(names(q: "6281000012345").first).to eq("Hair Mask")
    end

    it "an empty query lists the first products by name; nothing matching is an empty list" do
      expect(names(q: "")).to eq([ "Argan Shampoo", "Hair Mask", "Serum SH-1" ])
      expect(search(q: "zzz-nothing")).to eq([])
    end

    it "treats LIKE wildcards literally" do
      expect(search(q: "%")).to eq([])
      expect(search(q: "_")).to eq([])
    end
  end

  describe "kinds: the list each picker always offered" do
    let!(:plain)    { product("Plain", "PL-1") }
    let!(:archived) { product("Archived", "AR-1", active: false) }
    let!(:untracked) { product("Untracked", "UN-1", track_inventory: false) }

    it "transactable (document lines, requests, imports): every active product" do
      expect(names(kind: "transactable")).to contain_exactly("Plain", "Untracked")
    end

    it "tracked (branch comparison): active and inventory-tracked" do
      expect(names(kind: "tracked")).to contain_exactly("Plain")
    end

    it "all (report filters): every product, archived included" do
      expect(names(kind: "all")).to contain_exactly("Plain", "Archived", "Untracked")
    end

    it "defaults to transactable and refuses an unknown kind" do
      expect(names).to contain_exactly("Plain", "Untracked")
      get inventory_product_search_path(kind: "everything")
      expect(response).to have_http_status(:bad_request)
    end
  end

  it "never returns another business's products (ProductPolicy scope)" do
    product("Ours", "OU-1")
    create(:business).products.create!(name: "Theirs", sku: "OU-2")
    expect(names(q: "OU-")).to eq([ "Ours" ])
  end

  it "requires inventory access" do
    product("Ours", "OU-1")
    sign_in create(:user, business: business)
    get inventory_product_search_path(q: "OU")
    expect(response).not_to have_http_status(:ok)
  end

  it "returns at most 20 rows" do
    25.times { |i| product("Bulk #{i.to_s.rjust(2, '0')}", "BK-#{i}") }
    expect(search(q: "bulk").size).to eq(20)
  end

  it "the payload: id, name, SKU, barcodes, default supplier and the thumbnail (or none)" do
    with_image = product("Argan Oil", "AO-1", default_supplier: supplier)
    with_image.product_barcodes.create!(barcode: "111", is_primary: true)
    attach_product_image!(with_image)
    product("Argan Comb", "AO-2")

    by_name = search(q: "argan").index_by { |p| p["name"] }
    expect(by_name["Argan Oil"]).to include("id" => with_image.id, "sku" => "AO-1", "barcode" => "111",
                                            "default_supplier_id" => supplier.id)
    expect(by_name["Argan Oil"]["barcodes"]).to include("111") # with any generated barcode
    expect(by_name["Argan Oil"]["thumb"]).to include("/rails/active_storage/representations/")
    expect(by_name["Argan Comb"]).to include("thumb" => nil, "default_supplier_id" => nil)
  end

  it "a large catalogue: the same queries for 3 or 300 products, never a row-by-row load" do
    blob = ActiveStorage::Blob.create_and_upload!(io: File.open(Rails.root.join("spec/fixtures/files/test_image.png")),
                                                  filename: "p.png", content_type: "image/png")
    make = ->(range) { range.each { |i| product("Catalogue #{i}", "CT-#{i}").tap { |p| attach_product_image!(p, blob); p.product_barcodes.create!(barcode: "B#{i}") } } }
    count = lambda do
      get inventory_product_search_path(q: "catalogue") # warm
      n = 0
      counter = ->(*, payload) { n += 1 unless payload[:cached] || payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get inventory_product_search_path(q: "catalogue") }
      n
    end

    make.(0...3)
    small = count.()
    make.(3...300)
    expect(count.()).to eq(small)
    expect(response.parsed_body.size).to eq(20)
  end
end
