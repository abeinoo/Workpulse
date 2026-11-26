require "rails_helper"

# Products index warehouse context: one selected warehouse (or All
# warehouses) scopes every inventory figure on the page — summary cards,
# inventory value, the stock column, low / out-of-stock statuses, the stock
# filter and the product count. The id is resolved server-side against the
# viewer's reachable warehouses; anything else is refused.
RSpec.describe "Inventory::Products#index — warehouse context", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:north)   { business.warehouses.create!(name: "North Store") }
  let!(:south)   { business.warehouses.create!(name: "South Store") }
  let!(:branch)  { create(:branch, business: business, branch_type: "sales") }
  let!(:soap)    { business.products.create!(name: "Soap", sku: "SOAP-1", average_cost_price: 2) }
  let!(:towel)   { business.products.create!(name: "Towel", sku: "TWL-1", average_cost_price: 10) }

  # North: soap 10 (threshold 5 -> fine), towel none (out of stock).
  # South: soap 2 (threshold 5 -> low), towel 4.
  before do
    stock!(soap, north, 10)
    stock!(soap, south, 2)
    stock!(towel, south, 4)
    ProductWarehouseSetting.create!(product: soap, warehouse: north, low_stock_level: 5, reorder_quantity: 10)
    ProductWarehouseSetting.create!(product: soap, warehouse: south, low_stock_level: 5, reorder_quantity: 10)
  end

  def stock!(product, warehouse, quantity)
    InventoryMovement.create!(business: business, product: product, warehouse: warehouse, branch: branch, direction: :in,
                              reason: :opening_balance, quantity: quantity, unit_cost: product.average_cost_price,
                              occurred_on: Date.current)
  end

  def restricted_to(*warehouses)
    user_with_stock_permissions(business, :view_inventory).tap do |user|
      warehouses.each { |w| WarehouseAssignment.create!(user: user, warehouse: w) }
    end
  end

  def index_for(user, **query)
    sign_in user
    get inventory_products_path(query)
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  def card(doc, testid) = doc.at_css("[data-testid='#{testid}'] .products-summary__value").text.strip
  def stock_state(doc, product) = doc.at_css("#stock_product_#{product.id}")&.[]("data-stock-state")
  def stock_qty(doc, product) = doc.at_css("#stock_product_#{product.id}").text.squish
  def listed(doc) = doc.css(".product-cell__name").map { |a| a.text.strip }
  def count_badge(doc) = doc.at_css("[data-testid='products-count']").text.strip

  describe "switching warehouses" do
    it "shows each warehouse's own quantities, statuses and summary" do
      doc = index_for(owner, warehouse_id: north.id)
      expect(stock_qty(doc, soap)).to start_with("10")
      expect(stock_state(doc, soap)).to eq("in")
      expect(stock_state(doc, towel)).to eq("out")
      expect(card(doc, "summary-low-stock")).to eq("0")
      expect(card(doc, "summary-out-of-stock")).to eq("1")

      doc = index_for(owner, warehouse_id: south.id)
      expect(stock_qty(doc, soap)).to start_with("2")
      expect(stock_state(doc, soap)).to eq("low")
      expect(stock_qty(doc, towel)).to start_with("4")
      expect(stock_state(doc, towel)).to eq("in")
      expect(card(doc, "summary-low-stock")).to eq("1")
      expect(card(doc, "summary-out-of-stock")).to eq("0")
    end

    it "computes the inventory value for the selected warehouse only" do
      expect(card(index_for(owner, warehouse_id: north.id), "summary-stock-value")).to include("20.00")
      expect(card(index_for(owner, warehouse_id: south.id), "summary-stock-value")).to include("44.00")
    end

    it "marks the selected warehouse in the selector and the hint" do
      doc = index_for(owner, warehouse_id: south.id)

      expect(doc.at_css("[data-testid='warehouse-select'] option[selected]").text).to eq("South Store")
      expect(doc.at_css("[data-testid='warehouse-context-hint']").text).to include("South Store")
    end
  end

  describe "All warehouses" do
    it "is the default and aggregates every warehouse with the same figures everywhere" do
      doc = index_for(owner)

      expect(doc.at_css("[data-testid='warehouse-select'] option[selected]")&.text).to be_nil.or eq("All warehouses")
      expect(stock_qty(doc, soap)).to start_with("12")
      expect(stock_state(doc, soap)).to eq("low") # low in South by South's own threshold
      expect(stock_qty(doc, towel)).to start_with("4")
      expect(card(doc, "summary-low-stock")).to eq("1")
      expect(card(doc, "summary-out-of-stock")).to eq("0")
      expect(card(doc, "summary-stock-value")).to include("64.00")
    end

    it "aggregates only the warehouses a restricted viewer can reach" do
      doc = index_for(restricted_to(north))

      expect(stock_qty(doc, soap)).to start_with("10")
      expect(stock_state(doc, towel)).to eq("out")
      expect(card(doc, "summary-stock-value")).to include("20.00")
      expect(doc.css("[data-testid='warehouse-select'] option").map(&:text)).to eq([ "All warehouses", "North Store" ])
    end
  end

  describe "filters inside the warehouse context" do
    it "applies the stock-status filter against the selected warehouse" do
      expect(listed(index_for(owner, warehouse_id: north.id, stock_status: "out_of_stock"))).to eq([ "Towel" ])
      expect(listed(index_for(owner, warehouse_id: south.id, stock_status: "out_of_stock"))).to be_empty
      expect(listed(index_for(owner, warehouse_id: south.id, stock_status: "low_stock"))).to eq([ "Soap" ])
      expect(listed(index_for(owner, warehouse_id: north.id, stock_status: "low_stock"))).to be_empty
      expect(listed(index_for(owner, warehouse_id: north.id, stock_status: "in_stock"))).to eq([ "Soap" ])
    end

    it "searches within the context and keeps the count and summary consistent" do
      doc = index_for(owner, warehouse_id: north.id, q: "towel")

      expect(listed(doc)).to eq([ "Towel" ])
      expect(stock_state(doc, towel)).to eq("out")
      expect(count_badge(doc)).to eq("1 product")
      # The summary is the tab's whole catalogue in this warehouse, before search.
      expect(card(doc, "summary-total")).to eq("2")
      expect(card(doc, "summary-out-of-stock")).to eq("1")
    end

    it "keeps search and filters when the warehouse changes, and keeps the warehouse when filters change" do
      doc = index_for(owner, warehouse_id: north.id, q: "soap", stock_status: "in_stock", status: "all")

      context_fields = doc.css("[data-testid='warehouse-context'] input[type=hidden]").to_h { |i| [ i["name"], i["value"] ] }
      expect(context_fields).to include("q" => "soap", "stock_status" => "in_stock", "status" => "all")
      expect(context_fields).not_to have_key("warehouse_id")

      filter_form = doc.at_css("[data-testid='products-filters']")
      expect(filter_form.at_css("input[name=warehouse_id]")["value"]).to eq(north.id.to_s)
      expect(doc.at_css("[data-testid='clear-filters']")["href"]).to include("warehouse_id=#{north.id}")
      expect(doc.at_css("[data-testid='clear-filters']")["href"]).not_to include("q=")
      expect(doc.css("[data-testid='filter-chips'] a").map { |a| a["href"] }).to all(include("warehouse_id=#{north.id}"))
      expect(doc.css(".products-index__tabs a").map { |a| a["href"] }).to all(include("warehouse_id=#{north.id}"))
    end

    it "does not count the warehouse alone as a filter" do
      doc = index_for(owner, warehouse_id: north.id)

      expect(doc.at_css("[data-testid='clear-filters']")).to be_nil
      expect(doc.at_css("[data-testid='filter-chips']")).to be_nil
    end
  end

  describe "access control" do
    it "refuses a warehouse outside the restricted viewer's assignment" do
      sign_in restricted_to(north)
      get inventory_products_path(warehouse_id: south.id)

      expect(response).to redirect_to(root_path)
    end

    it "refuses another business's warehouse, even for an owner" do
      other = create(:business).warehouses.create!(name: "Elsewhere")
      sign_in owner
      get inventory_products_path(warehouse_id: other.id)

      expect(response).to redirect_to(root_path)
    end

    it "refuses an inactive warehouse and an unknown id" do
      south.update_column(:status, "inactive")
      sign_in owner
      get inventory_products_path(warehouse_id: south.id)
      expect(response).to redirect_to(root_path)

      get inventory_products_path(warehouse_id: "999999999")
      expect(response).to redirect_to(root_path)
    end

    it "never shows the other warehouse's stock in a selected warehouse's page" do
      doc = index_for(owner, warehouse_id: north.id)

      expect(stock_qty(doc, towel)).to start_with("0") # its 4 units are in South
      expect(stock_qty(doc, soap)).to start_with("10")
      expect(doc.to_html).not_to include("44.00", "64.00")
    end
  end
end
