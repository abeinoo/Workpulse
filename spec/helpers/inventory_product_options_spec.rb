require "rails_helper"

# The stock issue form renders the product catalog once per line-item row.
# Its fast path (Product.barcode_lookup + #inventory_product_options_html +
# #inventory_product_select_options) must produce exactly what the original
# per-product path (#inventory_product_options, Product#barcode) produced.
RSpec.describe InventoryHelper, type: :helper do
  let(:business) { create(:business) }

  # Products get an auto-generated primary barcode on create — cleared so each
  # fixture sets up exactly the barcode shape it names.
  def product!(sku)
    business.products.create!(name: "Name #{sku} \"quoted\" <b>&", sku: sku, initial_cost_price: 1, average_cost_price: 1)
            .tap { |p| p.product_barcodes.delete_all }
  end

  let!(:no_barcode)    { product!("NONE") }
  let!(:non_primary)   { product!("NP").tap { |p| p.product_barcodes.create!(barcode: "NP-1", is_primary: false) } }
  let!(:two_non_prim)  do
    product!("TWO").tap do |p|
      p.product_barcodes.create!(barcode: "TWO-first", is_primary: false)
      p.product_barcodes.create!(barcode: "TWO-second", is_primary: false)
    end
  end
  let!(:primary_later) do
    product!("PL").tap do |p|
      p.product_barcodes.create!(barcode: "PL-old", is_primary: false)
      p.product_barcodes.create!(barcode: "PL-primary", is_primary: true)
    end
  end
  let!(:sku_like_value) { product!(%(S" value="#{no_barcode.id})) }

  let(:products) { business.products.order(:name).to_a }

  describe "Product.barcode_lookup" do
    it "picks the same barcode as Product#barcode for every product, in one query" do
      fresh = Product.where(id: products.map(&:id)).to_a # associations not loaded
      lookup = nil
      expect(count_queries { lookup = Product.barcode_lookup(fresh.map(&:id)) }).to eq(1)

      fresh.each { |p| expect(lookup[p.id]).to eq(p.barcode), p.sku }
      expect(lookup).to include(non_primary.id => "NP-1", two_non_prim.id => "TWO-first", primary_later.id => "PL-primary")
      expect(lookup).not_to have_key(no_barcode.id)
    end

    it "is empty for no ids, without querying" do
      expect(count_queries { expect(Product.barcode_lookup([])).to eq({}) }).to eq(0)
    end
  end

  describe "#inventory_product_select_options" do
    it "renders byte-identical markup to #inventory_product_options for every selection" do
      fresh = Product.where(id: products.map(&:id)).order(:name).to_a
      html  = helper.inventory_product_options_html(fresh, barcodes: Product.barcode_lookup(fresh.map(&:id)))

      [ nil, "", *fresh.map(&:id), fresh.first.id.to_s, -1 ].each do |selected|
        expected = helper.inventory_product_options(Product.where(id: fresh.map(&:id)).order(:name).to_a, selected)
        expect(helper.inventory_product_select_options(html, selected)).to eq(expected), selected.inspect
      end
    end

    it "marks only the selected option even when another option's attributes mention that id" do
      fresh = Product.where(id: products.map(&:id)).order(:name).to_a
      html  = helper.inventory_product_options_html(fresh, barcodes: Product.barcode_lookup(fresh.map(&:id)))
      doc   = Nokogiri::HTML.fragment(helper.inventory_product_select_options(html, no_barcode.id))

      selected = doc.css("option[selected]")
      expect(selected.map { |o| o["value"] }).to eq([ no_barcode.id.to_s ])
      expect(helper.inventory_product_select_options(html, no_barcode.id)).to be_html_safe
    end
  end
end
