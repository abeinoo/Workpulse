require "rails_helper"

# Product thumbnails must not slow large inventory pages down: the images are
# preloaded with the products (ProductThumbnailHelper raises otherwise), so the
# number of Active Storage queries is the same for 3 products as for 200, and
# every row still gets its thumbnail. Only Active Storage queries are counted,
# isolating the thumbnail cost from each page's own work.
RSpec.describe "Product thumbnails — image loading performance", type: :request do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:blob) do
    ActiveStorage::Blob.create_and_upload!(io: File.open(Rails.root.join("spec/fixtures/files/test_image.png")),
                                           filename: "p.png", content_type: "image/png")
  end

  before { sign_in owner }

  # n products sharing one uploaded image (fast fixtures), every one low on
  # stock in the Main warehouse (threshold 5, nothing on hand).
  def products(count, from: 0)
    Array.new(count) do |i|
      business.products.create!(name: "Product #{from + i}", sku: "SKU-#{from + i}", average_cost_price: 5).tap do |p|
        attach_product_image!(p, blob)
        ProductWarehouseSetting.create!(product: p, warehouse: warehouse, low_stock_level: 5, reorder_quantity: 3)
      end
    end
  end

  # Measured on a warm second request, so per-page fixed costs that only show
  # up once (the signed-in user's avatar in the sidebar) don't skew the pair.
  def active_storage_queries
    yield
    count = 0
    counter = ->(*, payload) { count += 1 if !payload[:cached] && payload[:sql].include?("active_storage_") }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  def thumbnails = Nokogiri::HTML(response.body).css("img.pthumb__img")

  it "products index: constant image queries from 3 to 200 products, a thumbnail per row" do
    products(3)
    small = active_storage_queries { get inventory_products_path(per_page: 500) }
    products(197, from: 3)
    large = active_storage_queries { get inventory_products_path(per_page: 500) }

    expect(large).to eq(small)
    expect(large).to be <= 4 # product attachments + blobs (+ the sidebar avatar)
    expect(thumbnails.size).to be >= 25 # every rendered row (the page size) has its image
  end

  it "purchase request page: constant image queries however many lines" do
    build_request = lambda do |items|
      pr = business.purchase_requests.build(warehouse: warehouse, created_by: owner)
      items.each { |p| pr.items.build(product: p, quantity: 1, unit_price: 5) }
      pr.save!
      pr
    end
    small_pr = build_request.(products(3))
    large_pr = build_request.(products(120, from: 3))

    small = active_storage_queries { get inventory_purchase_request_path(small_pr) }
    large = active_storage_queries { get inventory_purchase_request_path(large_pr) }
    expect(large).to eq(small)
    expect(thumbnails.size).to eq(120)
  end

  it "new purchase request (Low Stock picker + product combobox): constant image queries, no catalogue in the page" do
    products(3)
    small = active_storage_queries { get new_inventory_purchase_request_path }
    products(150, from: 3)
    large = active_storage_queries { get new_inventory_purchase_request_path }

    expect(large).to eq(small)
    doc = Nokogiri::HTML(response.body)
    expect(doc.css("[data-low-stock-row] img.pthumb__img").size).to eq(153)
    # The line pickers search on demand: the catalogue is never in the page.
    expect(doc.css("[data-controller='product-combobox'] select option").map { |o| o["value"] }.compact_blank).to be_empty
  end

  it "inventory dashboard and current stock report: constant image queries" do
    products(3)
    dash_small   = active_storage_queries { get inventory_root_path }
    report_small = active_storage_queries { get inventory_current_stock_report_path }
    products(100, from: 3)
    expect(active_storage_queries { get inventory_root_path }).to eq(dash_small)
    expect(active_storage_queries { get inventory_current_stock_report_path }).to eq(report_small)
  end

  it "variant URLs are only generated (never processed) while rendering" do
    products(20)
    expect { get inventory_products_path }.not_to change(ActiveStorage::VariantRecord, :count)
  end
end
