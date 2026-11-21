require "rails_helper"

# Product New / Edit image gallery: photos are staged (uploaded with progress,
# unattached) and the ordered gallery is applied when the product is saved —
# together with the product, or not at all. The primary (first) image is the
# product's image everywhere.
RSpec.describe "Product image gallery", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:editor)   { user_with_stock_permissions(business, :view_inventory, :manage_products) }
  let(:viewer)   { user_with_stock_permissions(business, :view_inventory) }
  let(:product)  { business.products.create!(name: "Argan Oil", sku: "AO-1", initial_cost_price: 4, average_cost_price: 4) }

  def doc = Nokogiri::HTML(response.body)
  def photo = Rack::Test::UploadedFile.new(ProductImageHelpers::TEST_IMAGE, "image/png")

  def stage!
    post inventory_product_image_uploads_path, params: { file: photo }, headers: { "Accept" => "application/json" }
    expect(response).to have_http_status(:created)
    response.parsed_body["signed_id"]
  end

  def save(product_attrs = {}, gallery: nil)
    attrs = { name: product.name, sku: product.sku }.merge(product_attrs)
    attrs = attrs.merge(gallery_present: "1", gallery: gallery) unless gallery.nil?
    patch inventory_product_path(product), params: { product: attrs }
  end

  describe "staging uploads" do
    before { sign_in owner }

    it "answers a signed id for a valid photo and attaches nothing" do
      expect(stage!).to be_present
      expect(ProductImage.count).to eq(0)
    end

    it "refuses a file that is not a real image, with a translated message" do
      fake = Tempfile.new([ "fake", ".png" ]).tap { |f| f.write("nope"); f.rewind }
      post inventory_product_image_uploads_path, params: { file: Rack::Test::UploadedFile.new(fake.path, "image/png") }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq(I18n.t("inventory.products.gallery.errors.invalid_type"))
    end

    it "is refused for a user who may not edit products" do
      sign_in viewer
      expect { post inventory_product_image_uploads_path, params: { file: photo } }.not_to change(ActiveStorage::Blob, :count)
      expect(response).to redirect_to(root_path)
    end
  end

  describe "creating a product" do
    before { sign_in editor }

    it "with several photos: saved in order, the first is the primary image" do
      first, second = stage!, stage!
      post inventory_products_path, params: { product: { name: "Shampoo", sku: "SH-1", initial_cost_price: 2,
                                                         gallery_present: "1", gallery: [ "upload:#{second}", "upload:#{first}" ] } }
      created = business.products.find_by!(sku: "SH-1")
      expect(response).to redirect_to(inventory_product_path(created))
      expect(created.images.map { |i| i.file.blob.signed_id(purpose: Inventory::ProductGalleryUpdater::STAGE_PURPOSE) }.size).to eq(2)
      expect(created.primary_image.file.blob).to eq(ActiveStorage::Blob.find_signed(second, purpose: Inventory::ProductGalleryUpdater::STAGE_PURPOSE))
    end

    it "without photos (and from a form without the gallery, like the import modal)" do
      post inventory_products_path, params: { product: { name: "Comb", sku: "CB-1", initial_cost_price: 1, gallery_present: "1" } }
      expect(business.products.find_by!(sku: "CB-1").images).to be_empty
      post inventory_products_path, params: { product: { name: "Brush", sku: "BR-1", initial_cost_price: 1 } }
      expect(business.products.find_by!(sku: "BR-1").images).to be_empty
    end

    it "a refused gallery creates no product, and the form shows the error with the uploaded photo kept" do
      signed = stage!
      post inventory_products_path, params: { product: { name: "Gel", sku: "GL-1", initial_cost_price: 1,
                                                         gallery_present: "1", gallery: [ "upload:#{signed}", "upload:forged" ] } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(business.products.find_by(sku: "GL-1")).to be_nil
      expect(response.body).to include(I18n.t("inventory.products.gallery.errors.invalid_upload"))
      expect(doc.css("input[name='product[gallery][]']").map { |i| i["value"] }).to eq([ "upload:#{signed}" ])
    end
  end

  describe "editing a product" do
    let!(:a) { attach_product_image!(product) }
    let!(:b) { attach_product_image!(product) }

    before { sign_in editor }

    it "shows the gallery beside the form: the primary image large, every photo as a thumbnail, in order" do
      get edit_inventory_product_path(product)
      expect(response).to have_http_status(:ok)
      gallery = doc.at_css("[data-testid='product-gallery']")
      expect(gallery.ancestors(".product-editor__aside")).to be_present
      expect(gallery.at_css("[data-testid='gallery-main'] img")["src"]).to include("/representations/")
      expect(gallery.css("ol.pgallery__thumbs > [data-testid='gallery-item']").map { |li| li["data-entry"] }).to eq([ "image:#{a.id}", "image:#{b.id}" ])
      expect(gallery.css("input[name='product[gallery][]']").map { |i| [ i["value"], i["form"] ] })
        .to eq([ [ "image:#{a.id}", "product-form" ], [ "image:#{b.id}", "product-form" ] ])
      expect(doc.css("input[type='file'][name='product[image]']")).to be_empty # the old single-photo field is gone
    end

    it "keeps every image untouched when the gallery is saved unchanged, or not sent at all" do
      before = ProductImage.order(:id).map(&:attributes)
      save({ name: "Argan Oil Pro" }, gallery: [ "image:#{a.id}", "image:#{b.id}" ])
      expect(response).to redirect_to(inventory_product_path(product))
      save({ name: "Argan Oil Max" })
      expect(product.reload.name).to eq("Argan Oil Max")
      expect(ProductImage.order(:id).map(&:attributes)).to eq(before)
    end

    it "persists a new order and primary image, adds and removes photos" do
      signed = stage!
      save({}, gallery: [ "image:#{b.id}", "upload:#{signed}" ])
      expect(response).to redirect_to(inventory_product_path(product))
      images = product.images.reload
      expect(images.first).to eq(b)
      expect(images.map(&:position)).to eq([ 1, 2 ])
      expect(ProductImage.exists?(a.id)).to be(false)

      get edit_inventory_product_path(product)
      expect(doc.css("ol.pgallery__thumbs > [data-testid='gallery-item']").map { |li| li["data-entry"] }).to eq(images.map { |i| "image:#{i.id}" })
    end

    it "rolls the product change back too when the gallery is refused" do
      other_product = business.products.create!(name: "Other", sku: "OT-1", initial_cost_price: 1, average_cost_price: 1)
      theirs = attach_product_image!(other_product)
      save({ name: "Renamed" }, gallery: [ "image:#{theirs.id}" ])
      expect(response).to have_http_status(:unprocessable_entity)
      expect(product.reload.name).to eq("Argan Oil")
      expect(product.images.reload.map(&:id)).to eq([ a.id, b.id ])
      expect(theirs.reload.product).to eq(other_product)
    end

    it "a user who may not edit products cannot change the gallery" do
      sign_in viewer
      save({}, gallery: [])
      expect(response).to redirect_to(root_path)
      expect(product.images.reload.size).to eq(2)
    end

    it "the primary image is the product's image in lists and on its page" do
      save({}, gallery: [ "image:#{b.id}", "image:#{a.id}" ])
      primary_blob_key = b.file.blob.key
      get inventory_products_path
      thumb = doc.css("tr").find { |tr| tr.text.include?("AO-1") }.at_css("img.pthumb__img")
      expect(thumb["src"]).to include("/representations/")
      expect(Product.with_primary_image.find(product.id).primary_image.file.blob.key).to eq(primary_blob_key)
      get inventory_product_path(product)
      expect(doc.at_css(".page-title img.pthumb__img")).to be_present
    end
  end

  describe "languages" do
    before do
      attach_product_image!(product)
      sign_in owner
    end

    { "en" => [ "ltr", "Photos", "Add photos" ], "ar" => [ "rtl", "الصور", "إضافة صور" ] }.each do |locale, (dir, title, add)|
      it "renders the gallery in #{locale} (#{dir})" do
        owner.update!(preferred_locale: locale)
        [ edit_inventory_product_path(product), new_inventory_product_path ].each do |path|
          get path
          expect(response).to have_http_status(:ok)
          expect(response.body).to include(%(dir="#{dir}"), title, add)
          expect(response.body).not_to include("translation missing")
        end
      end
    end
  end
end
