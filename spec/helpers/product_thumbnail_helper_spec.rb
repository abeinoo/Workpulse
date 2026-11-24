require "rails_helper"

# The one product identity component: thumbnail (tracked :thumb variant,
# lazy, fixed size) or the CSS placeholder, beside the name and optional SKU.
# Images are read only when preloaded — in tests a missing preload raises.
RSpec.describe ProductThumbnailHelper, type: :helper do
  let(:business) { create(:business) }
  let(:product)  { business.products.create!(name: "Argan Oil", sku: "AO-1") }

  def with_image(record)
    attach_product_image!(record, filename: "argan.png")
    record
  end

  def preloaded(record) = Product.with_primary_image.find(record.id)
  def html(markup) = Nokogiri::HTML.fragment(markup)

  describe "#product_thumbnail" do
    it "renders the product's thumb variant: fixed size, lazy, decorative, fitted by CSS" do
      img = html(helper.product_thumbnail(preloaded(with_image(product)), size: :md)).at_css(".pthumb.pthumb--md img.pthumb__img")

      expect(img).to be_present
      expect(img["src"]).to include("/rails/active_storage/representations/")
      expect(img.attributes.slice("width", "height", "loading", "decoding", "alt").transform_values(&:value))
        .to eq("width" => "44", "height" => "44", "loading" => "lazy", "decoding" => "async", "alt" => "")
    end

    it "uses the larger variant only for :lg" do
      thumb = html(helper.product_thumbnail(preloaded(with_image(product)), size: :sm)).at_css("img")["src"]
      large = html(helper.product_thumbnail(preloaded(product), size: :lg)).at_css("img")["src"]
      expect(thumb).not_to eq(large)
    end

    it "renders the placeholder (no <img>) for a product without an image" do
      node = html(helper.product_thumbnail(preloaded(product))).at_css(".pthumb")
      expect(node["class"]).to include("pthumb--empty")
      expect(node["aria-hidden"]).to eq("true")
      expect(node.at_css("img")).to be_nil
    end

    it "renders the placeholder for an image that can't be thumbnailed" do
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("not an image"), filename: "x.txt", content_type: "text/plain")
      image = ProductImage.new(product: product, business: business, position: 1).tap { |row| row.save!(validate: false) } # bypassing validations
      ActiveStorage::Attachment.create!(record: image, name: "file", blob: blob)

      expect(html(helper.product_thumbnail(preloaded(product))).at_css(".pthumb--empty")).to be_present
    end

    it "raises in tests when the image wasn't preloaded (an N+1 on a list)" do
      expect { helper.product_thumbnail(Product.find(product.id)) }.to raise_error(ProductThumbnailHelper::ImageNotPreloaded)
    end
  end

  describe "#product_identity" do
    it "thumbnail + linked name + SKU (left-to-right) as secondary text" do
      node = html(helper.product_identity(preloaded(product), sku: true, link: "/p/1")).at_css(".pident.pident--sm")

      expect(node.at_css(".pthumb")).to be_present
      expect(node.at_css(".pident__name a[href='/p/1']").text).to eq("Argan Oil")
      expect(node.at_css(".pident__sku").text).to eq("AO-1")
      expect(node.at_css(".pident__sku")["dir"]).to eq("ltr")
    end

    it "no SKU unless asked, plain name without a link, and a dash for no product" do
      node = html(helper.product_identity(preloaded(product)))
      expect(node.at_css(".pident__sku")).to be_nil
      expect(node.at_css("a")).to be_nil
      expect(helper.product_identity(nil)).to eq("—")
    end
  end

  describe "#product_thumbnail_url(preloaded_only: true)" do
    it "gives a URL only for preloaded images, never querying for the others" do
      with_image(product)
      not_loaded = Product.find(product.id)

      expect(helper.product_thumbnail_url(not_loaded, preloaded_only: true)).to be_nil
      expect(helper.product_thumbnail_url(preloaded(product), preloaded_only: true)).to include("/representations/")
    end

    it "is nil for no product" do
      expect(helper.product_thumbnail_url(nil)).to be_nil
    end
  end

  describe "#product_combobox" do
    before { allow(helper).to receive(:inventory_product_search_path).and_return("/inventory/product_search") }

    let(:builder) do
      ActionView::Helpers::FormBuilder.new("goods_receipt[items_attributes][0]", GoodsReceiptItem.new, helper, {})
    end

    it "an ARIA combobox submitting through a hidden <select> holding only the selected product's option" do
      selected = Product.with_primary_image.includes(:product_barcodes).find(with_image(product).id)
      node = html(helper.product_combobox(builder, :product_id, selected: selected, kind: "tracked",
                                          select_data: { product_field: true, action: "change->x#y" })).at_css(".pcombo")

      expect(node["data-controller"]).to eq("product-combobox")
      expect(node["data-product-combobox-url-value"]).to eq("/inventory/product_search")
      expect(node["data-product-combobox-kind-value"]).to eq("tracked")
      select = node.at_css("select")
      expect(select["name"]).to eq("goods_receipt[items_attributes][0][product_id]")
      expect(select["hidden"]).to be_present
      expect(select["data-product-field"]).to eq("true")
      expect(select["data-action"]).to eq("change->x#y")
      option = select.at_css("option[selected]")
      expect(option["value"]).to eq(product.id.to_s)
      expect(option.attributes.slice("data-name", "data-sku").transform_values(&:value)).to eq("data-name" => "Argan Oil", "data-sku" => "AO-1")
      expect(option["data-thumb"]).to include("/representations/")
      expect(select.css("option").size).to eq(2) # blank + the selected product, never the catalogue

      input = node.at_css("input[role='combobox']")
      expect(input["id"]).to eq("goods_receipt_items_attributes_0_product_id")
      expect(input["aria-controls"]).to eq(node.at_css("ul[role='listbox']")["id"])
      expect(input["aria-autocomplete"]).to eq("list")
      expect(input["aria-expanded"]).to eq("false")
    end

    it "with no selection: only the blank option, and a field without a name for plain forms" do
      node = html(helper.product_combobox(nil, :product_id, name: "product_id", id: "product_id", blank: "All"))
      expect(node.css("select option").map { |o| [ o["value"], o.text ] }).to eq([ [ "", "All" ] ])
      expect(node.at_css("select")["name"]).to eq("product_id")
    end
  end
end
