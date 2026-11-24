require "rails_helper"

# Barcodes on Product New / Edit (nested product_barcodes): deleting persists
# only on Save and only for the rows marked; a barcode is unique across the
# whole business (every product — active or archived — and every barcode
# type), case-insensitively after trimming; swaps and re-use within one save
# work; the unique index is the final guarantee and surfaces as a message.
RSpec.describe "Product barcode management", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }

  def product!(sku, *barcodes, biz: business)
    biz.products.create!(name: "Product #{sku}", sku: sku, initial_cost_price: 1, average_cost_price: 1).tap do |p|
      barcodes.each_with_index do |(code, type), i|
        p.product_barcodes.create!(barcode: code, barcode_type: type || "manufacturer", is_primary: i.zero?)
      end
    end
  end

  def rows(product) = product.product_barcodes.reload.order(:id).pluck(:barcode, :barcode_type, :is_primary)
  def doc = Nokogiri::HTML(response.body)

  # The Edit form's barcode rows, as the browser submits them.
  def save(product, rows_attrs, **product_attrs)
    attrs = { name: product.name, sku: product.sku }.merge(product_attrs)
    attrs[:product_barcodes_attributes] = rows_attrs.each_with_index.to_h { |row, i| [ i.to_s, row ] }
    patch inventory_product_path(product), params: { product: attrs }
  end

  def existing(pb, destroy: false, **changes)
    { id: pb.id, barcode: pb.barcode, barcode_type: pb.barcode_type, is_primary: pb.is_primary ? "1" : "0",
      _destroy: destroy ? "1" : "0" }.merge(changes)
  end

  before { sign_in owner }

  describe "creating a product" do
    def create_product(sku, barcodes = {})
      post inventory_products_path, params: { product: { name: "New #{sku}", sku: sku, initial_cost_price: 2,
                                                         product_barcodes_attributes: barcodes } }
      business.products.find_by(sku: sku)
    end

    it "without a barcode: succeeds and creates no barcode record (nothing generated)" do
      expect { create_product("NB-1") }.not_to change(ProductBarcode, :count)
      created = business.products.find_by!(sku: "NB-1")
      expect(response).to redirect_to(inventory_product_path(created))
      expect(created.product_barcodes).to be_empty
      expect(created.barcode).to be_nil

      create_product("NB-2", { "0" => { barcode: "", barcode_type: "manufacturer", is_primary: "1" } }) # the New form's blank row
      expect(business.products.find_by!(sku: "NB-2").product_barcodes).to be_empty
    end

    it "with a manually entered barcode (leading zeros kept): exactly that barcode" do
      created = create_product("MB-1", { "0" => { barcode: " 00123 ", barcode_type: "manufacturer", is_primary: "1" } })
      expect(rows(created)).to eq([ [ "00123", "manufacturer", true ] ])
    end

    it "with an explicitly generated barcode (Generate Barcode fills the row; Save inserts it)" do
      get next_barcode_code_inventory_products_path, as: :json
      code = response.parsed_body["code"]
      expect(ProductBarcode.count).to eq(0) # generating wrote nothing
      created = create_product("GB-1", { "0" => { barcode: code, barcode_type: "internal", is_primary: "1" } })
      expect(rows(created)).to eq([ [ code, "internal", true ] ])
    end
  end

  describe "deleting" do
    let!(:product) { product!("A", "111", "222", "333") }

    it "removes exactly the marked barcode on Save, keeping the others and the product; it stays gone after reload" do
      a, b, c = product.product_barcodes.order(:id).to_a
      save(product, [ existing(a), existing(b, destroy: true), existing(c) ])
      expect(response).to redirect_to(inventory_product_path(product))
      expect(rows(product)).to eq([ [ "111", "manufacturer", true ], [ "333", "manufacturer", false ] ])
      expect(Product.exists?(product.id)).to be(true)

      get edit_inventory_product_path(product)
      expect(doc.css("[data-line-items-target='rows'] input[name$='[barcode]']").map { |i| i["value"] }).to eq(%w[111 333])
    end

    it "deleting the primary barcode saves, and no other barcode is made primary on its own" do
      a, b, c = product.product_barcodes.order(:id).to_a
      save(product, [ existing(a, destroy: true), existing(b), existing(c) ])
      expect(response).to redirect_to(inventory_product_path(product))
      expect(rows(product)).to eq([ [ "222", "manufacturer", false ], [ "333", "manufacturer", false ] ])

      save(product, [ existing(b.reload), existing(c.reload, is_primary: "1") ]) # the user chooses a new primary
      expect(rows(product)).to eq([ [ "222", "manufacturer", false ], [ "333", "manufacturer", true ] ])
    end

    it "deleting every barcode saves; reopening shows none (no spare row); barcodes can be added again later" do
      save(product, product.product_barcodes.order(:id).map { |pb| existing(pb, destroy: true) })
      expect(response).to redirect_to(inventory_product_path(product))
      expect(rows(product)).to be_empty
      follow_redirect!
      expect(response.body).to include(I18n.t("inventory.products.all_saved"))

      get edit_inventory_product_path(product)
      expect(doc.css("[data-line-items-target='rows'] [data-line-row]")).to be_empty
      expect(doc.at_css("[data-line-items-target='emptyState']")["hidden"]).to be_nil
      expect(ProductBarcode.where(product: product).count).to eq(0) # opening the page generates nothing

      save(product, [ { barcode: "111", barcode_type: "manufacturer", is_primary: "1" } ]) # 111 was freed
      expect(response).to redirect_to(inventory_product_path(product))
      expect(rows(product)).to eq([ [ "111", "manufacturer", true ] ])
    end

    it "a product without barcodes saves with blank optional rows, and stays searchable by name and SKU" do
      save(product, product.product_barcodes.order(:id).map { |pb| existing(pb, destroy: true) })
      save(product, [ { barcode: "", barcode_type: "manufacturer", is_primary: "0" }, { barcode: "   ", barcode_type: "carton", is_primary: "1" } ],
           name: "Argan Shampoo")
      expect(response).to redirect_to(inventory_product_path(product))
      expect(rows(product)).to be_empty

      get inventory_product_search_path(q: "argan shamp"), as: :json
      expect(response.parsed_body.map { |p| p["id"] }).to eq([ product.id ])
      get inventory_product_search_path(q: "A"), as: :json
      expect(response.parsed_body.map { |p| p["id"] }).to include(product.id)
      get inventory_barcode_lookup_path(code: "a"), as: :json
      expect(response.parsed_body).to include("id" => product.id, "matched_on" => "sku")
    end

    it "a new row removed before Save (not submitted) — or left empty — creates nothing" do
      a, b, c = product.product_barcodes.order(:id).to_a
      expect { save(product, [ existing(a), existing(b), existing(c), { barcode: "", barcode_type: "manufacturer", is_primary: "0" } ]) }
        .not_to change(ProductBarcode, :count)
      expect(response).to redirect_to(inventory_product_path(product))
    end

    it "a refused Save deletes nothing, and the form keeps the row marked (hidden)" do
      a, b, c = product.product_barcodes.order(:id).to_a
      save(product, [ existing(a), existing(b, destroy: true), existing(c) ], name: "")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(rows(product).map(&:first)).to eq(%w[111 222 333])
      marked = doc.css("input[name$='[_destroy]']").find { |i| i["value"] == "1" }
      expect(marked).to be_present
      expect(marked.ancestors("[data-line-row]").first["hidden"]).not_to be_nil
    end

    it "emptying an existing barcode's value removes it (the same as its ×)" do
      a, b, c = product.product_barcodes.order(:id).to_a
      save(product, [ existing(a), existing(b, barcode: "  "), existing(c) ])
      expect(response).to redirect_to(inventory_product_path(product))
      expect(rows(product).map(&:first)).to eq(%w[111 333])
    end

    it "Generate barcode never writes on its own (the code fills a row saved with the product)" do
      expect { get next_barcode_code_inventory_products_path, as: :json }.not_to change(ProductBarcode, :count)
      get edit_inventory_product_path(product)
      expect(response.body).not_to include("generate-save-url")
    end
  end

  describe "business-wide uniqueness" do
    let!(:product)  { product!("A", "123456") }
    let!(:second)   { product!("B", "999") }

    it "refuses another product's barcode in the same business — any type, any case, surrounding spaces — with a message" do
      [ [ "123456", "manufacturer" ], [ "123456", "carton" ], [ " 123456 ", "internal" ] ].each do |code, type|
        save(second, [ existing(second.product_barcodes.first), { barcode: code, barcode_type: type, is_primary: "0" } ])
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to include("has already been taken")
      end
      letters = product!("L", "AbC-9")
      save(second, [ existing(second.product_barcodes.first), { barcode: "abc-9", barcode_type: "manufacturer", is_primary: "0" } ])
      expect(response).to have_http_status(:unprocessable_entity)
      expect(rows(second).map(&:first)).to eq(%w[999])
      expect(rows(letters).map(&:first)).to eq(%w[AbC-9])
    end

    it "applies to archived products too" do
      product.update!(active: false, archived_at: Time.current)
      save(second, [ existing(second.product_barcodes.first), { barcode: "123456", barcode_type: "manufacturer", is_primary: "0" } ])
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "allows the same barcode in another business" do
      foreign = product!("F", "555", biz: other)
      save(second, [ existing(second.product_barcodes.first), { barcode: "555", barcode_type: "manufacturer", is_primary: "0" } ])
      expect(response).to redirect_to(inventory_product_path(second))
      expect(rows(foreign).map(&:first)).to eq(%w[555])
      expect(rows(second).map(&:first)).to eq(%w[999 555])
    end

    it "keeps a product's own barcode on an unchanged save, stores the value as typed (string, leading zeros) after trimming" do
      save(product, [ existing(product.product_barcodes.first), { barcode: "  0012300 ", barcode_type: "carton", is_primary: "0" } ])
      expect(response).to redirect_to(inventory_product_path(product))
      expect(rows(product)).to eq([ [ "123456", "manufacturer", true ], [ "0012300", "carton", false ] ])
    end

    it "swaps two barcodes of one product, and re-uses a deleted barcode's value, in one save" do
      both = product!("S", "AAA1", "BBB2")
      a, b = both.product_barcodes.order(:id).to_a
      save(both, [ existing(a, barcode: "BBB2"), existing(b, barcode: "AAA1") ])
      expect(response).to redirect_to(inventory_product_path(both))
      expect(rows(both).map(&:first)).to eq(%w[BBB2 AAA1])

      save(both, [ existing(a.reload, destroy: true), existing(b.reload), { barcode: "BBB2", barcode_type: "carton", is_primary: "0" } ])
      expect(response).to redirect_to(inventory_product_path(both))
      # The deleted row was the primary: none is promoted automatically.
      expect(rows(both)).to eq([ [ "AAA1", "manufacturer", false ], [ "BBB2", "carton", false ] ])
    end

    it "two rows with the same value in one save get a message, not a database error" do
      save(second, [ existing(second.product_barcodes.first), { barcode: "777", barcode_type: "manufacturer", is_primary: "0" },
                     { barcode: "777 ", barcode_type: "carton", is_primary: "0" } ])
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(I18n.t("activerecord.errors.models.product.attributes.base.duplicate_barcodes", barcodes: "777"))
      expect(rows(second).map(&:first)).to eq(%w[999])
    end

    it "a duplicate only the unique index catches (a concurrent save) becomes a message and changes nothing" do
      allow_any_instance_of(ProductBarcode).to receive(:barcode_unique_in_business) # the other save validated first
      save(second, [ existing(second.product_barcodes.first), { barcode: "123456", barcode_type: "manufacturer", is_primary: "0" } ], name: "Renamed")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(I18n.t("activerecord.errors.models.product.attributes.base.barcode_taken"))
      expect(second.reload.name).to eq("Product B")
      expect(rows(second).map(&:first)).to eq(%w[999])
    end

    it "refuses control characters and creating a product with a taken barcode" do
      post inventory_products_path, params: { product: { name: "New", sku: "N-1", initial_cost_price: 1,
                                                         product_barcodes_attributes: { "0" => { barcode: "123456", barcode_type: "internal", is_primary: "1" } } } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(business.products.find_by(sku: "N-1")).to be_nil
      expect(ProductBarcode.new(product: second, barcode: "12\u000134", barcode_type: "manufacturer")).not_to be_valid
    end
  end
end

RSpec.describe "Product barcode uniqueness — concurrent saves (two connections)" do
  include_context "non-transactional database"

  it "two saves of the same new barcode, both validated before either inserts: exactly one wins" do
    business = create(:business)
    products = %w[C1 C2].map { |sku| business.products.create!(name: "Product #{sku}", sku: sku, initial_cost_price: 1, average_cost_price: 1) }
    ready = Queue.new
    go    = Queue.new
    threads = products.map do |product|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          record = Product.find(product.id)
          Product.transaction do
            record.assign_attributes(product_barcodes_attributes: [ { barcode: "424242", barcode_type: "manufacturer" } ])
            raise "should validate" unless record.valid?
            ready << true
            go.pop
            record.save!
          end
          :saved
        rescue ActiveRecord::RecordNotUnique
          :refused_by_unique_index
        end
      end
    end
    2.times { ready.pop }
    2.times { go << true }

    expect(threads.map { |t| t.join(15)&.value }.sort).to eq(%i[refused_by_unique_index saved])
    expect(ProductBarcode.where(business_id: business.id, barcode: "424242").count).to eq(1)
  end
end
