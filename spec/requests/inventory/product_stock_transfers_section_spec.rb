require "rails_helper"

# Product Show page — "Branch Transfers" section (التحويلات بين الفروع):
# stock transfers carrying the product (Inventory::ProductRecentDocuments
# #stock_transfers / #stock_transfer_summary). Read-only. Visibility follows
# StockTransferPolicy::Scope (a transfer is listed when the viewer reaches
# either end); the branch of an end the viewer does not reach is not shown.
#
# Transfers are built directly (no StockTransferPoster): the section reads
# documents only, and no stock is needed to display them.
RSpec.describe "Product page — branch transfers section", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:creator)  { create(:user, business: business, first_name: "Omar", last_name: "Nabil") }

  let!(:north)    { create(:branch, business: business, name: "North Branch", branch_type: "sales") }
  let!(:south)    { create(:branch, business: business, name: "South Branch", branch_type: "sales") }
  let!(:north_wh) { business.warehouses.create!(name: "North Store", kind: "branch", branch: north) }
  let!(:south_wh) { business.warehouses.create!(name: "South Store", kind: "branch", branch: south) }
  let!(:central)  { business.warehouses.create!(name: "Main Depot", kind: "central") }

  let!(:product) { business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0) }
  let!(:other)   { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 0, average_cost_price: 0) }

  def transfer!(from, to, lines: { product => 2 }, on: Date.current, voided: false, by: creator)
    @seq = (@seq || 0) + 1
    t = business.stock_transfers.build(source_warehouse: from, destination_warehouse: to, transferred_on: on,
                                       transfer_number: "TR-#{format('%04d', @seq)}", created_by: by)
    lines.each_pair { |p, qty| Array(qty).each { |q| t.items.build(product: p, quantity: q, unit_cost: 1) } }
    t.save!
    t.update_columns(voided_at: Time.current) if voided
    t
  end

  def restricted_to(*warehouses)
    user_with_stock_permissions(business, :view_inventory).tap do |user|
      warehouses.each { |w| WarehouseAssignment.create!(user: user, warehouse: w) }
    end
  end

  def visit_product(user, locale: nil)
    user.update_column(:preferred_locale, locale) if locale
    sign_in user
    get inventory_product_path(product)
    expect(response).to have_http_status(:ok)
  end

  def page = Nokogiri::HTML(response.body)
  def section = page.at_css("[data-testid='product-stock-transfers']")
  def numbers = section.css("tbody tr[data-recent-document]").map { |tr| tr["data-recent-document"] }
  def row(number) = section.at_css("tr[data-recent-document='#{number}']")
  def summary(key) = section.at_css("[data-testid='stock-transfer-#{key}']").text.squish

  describe "an unrestricted viewer" do
    let!(:out_t)  { transfer!(north_wh, south_wh, on: Date.current - 2) }
    let!(:in_t)   { transfer!(central, north_wh, on: Date.current - 1) }
    let!(:else_t) { transfer!(south_wh, central, on: Date.current) }

    it "sees every transfer of the product, newest first, each linked to its document" do
      visit_product(owner)

      expect(numbers).to eq([ else_t, in_t, out_t ].map(&:transfer_number))
      expect(row(out_t.transfer_number).at_css("a")["href"]).to eq(inventory_stock_transfer_path(out_t))
      expect(row(out_t.transfer_number).text).to include("Omar Nabil")
    end

    it "sees both ends' branches (or the Central badge) and no viewer-relative direction" do
      visit_product(owner)

      out_row = row(out_t.transfer_number)
      expect(out_row.at_css("[data-testid='transfer-source-branch']").text).to include("North Branch")
      expect(out_row.at_css("[data-testid='transfer-destination-branch']").text).to include("South Branch")
      expect(row(in_t.transfer_number).at_css("[data-testid='transfer-source-branch']").text)
        .to include(I18n.t("inventory.warehouses.kinds.central"))
      expect(section.css("thead th").map { |th| th.text.squish })
        .not_to include(I18n.t("inventory.products.show_layout.transfers.direction"))
    end
  end

  describe "a viewer restricted to some warehouses" do
    let!(:out_t)  { transfer!(north_wh, south_wh, on: Date.current - 2) }
    let!(:in_t)   { transfer!(central, north_wh, on: Date.current - 1) }
    let!(:else_t) { transfer!(south_wh, central, on: Date.current) }

    it "sees only transfers touching their warehouse, and counts only those" do
      visit_product(restricted_to(north_wh))

      expect(numbers).to contain_exactly(out_t.transfer_number, in_t.transfer_number)
      expect(summary("total")).to eq("2")
      expect(summary("posted")).to eq("2")
    end

    it "labels each transfer outgoing or incoming from their side" do
      visit_product(restricted_to(north_wh))
      tk = "inventory.products.show_layout.transfers.directions"

      expect(row(out_t.transfer_number).text).to include(I18n.t("#{tk}.outgoing"))
      expect(row(in_t.transfer_number).text).to include(I18n.t("#{tk}.incoming"))
    end

    it "never reveals the branch of the end they cannot reach (the warehouse name stays, as on the transfer page)" do
      visit_product(restricted_to(north_wh))

      out_row = row(out_t.transfer_number)
      expect(out_row.at_css("[data-testid='transfer-source-branch']").text).to include("North Branch")
      expect(out_row.at_css("[data-testid='transfer-destination-branch']")).to be_nil
      expect(out_row.text).to include("South Store")
      expect(section.text).not_to include("South Branch")

      in_row = row(in_t.transfer_number)
      expect(in_row.at_css("[data-testid='transfer-source-branch']")).to be_nil
      expect(in_row.at_css("[data-testid='transfer-destination-branch']").text).to include("North Branch")
    end

    it "sees both branches, labelled internal, when they reach both ends" do
      visit_product(restricted_to(north_wh, south_wh))
      out_row = row(out_t.transfer_number)

      expect(out_row.text).to include(I18n.t("inventory.products.show_layout.transfers.directions.internal"))
      expect(out_row.at_css("[data-testid='transfer-source-branch']").text).to include("North Branch")
      expect(out_row.at_css("[data-testid='transfer-destination-branch']").text).to include("South Branch")
    end

    it "sees nothing when their warehouse has no transfer of the product" do
      quiet = business.warehouses.create!(name: "Quiet Store")
      visit_product(restricted_to(quiet))

      expect(numbers).to be_empty
      expect(summary("total")).to eq("0")
      expect(section.text).to include(I18n.t("inventory.products.show_layout.transfers.empty"))
    end
  end

  it "never lists another business's transfer, even one pointing at this product" do
    elsewhere = create(:business)
    a = elsewhere.warehouses.create!(name: "Foreign A")
    b = elsewhere.warehouses.create!(name: "Foreign B")
    foreign_product = elsewhere.products.create!(name: "X", sku: "X-1", initial_cost_price: 0, average_cost_price: 0)
    foreign = elsewhere.stock_transfers.build(source_warehouse: a, destination_warehouse: b, transferred_on: Date.current,
                                              transfer_number: "FX-1")
    foreign.items.build(product: foreign_product, quantity: 9, unit_cost: 1)
    foreign.save!
    foreign.items.first.update_columns(product_id: product.id) # a corrupt cross-business line

    visit_product(owner)

    expect(numbers).not_to include("FX-1")
    expect(summary("total")).to eq("0")
  end

  describe "statuses and quantities" do
    it "shows a voided transfer struck through and counts posted and voided apart" do
      posted = transfer!(north_wh, south_wh)
      voided = transfer!(south_wh, north_wh, voided: true)
      visit_product(owner)

      expect(row(posted.transfer_number).at_css("[data-stock-effect]")["data-stock-effect"]).to eq("posted")
      expect(row(voided.transfer_number).at_css("[data-stock-effect]")["data-stock-effect"]).to eq("reversed")
      expect(row(voided.transfer_number).at_css("s")).to be_present
      expect(row(voided.transfer_number).at_css(".badge-danger").text).to include(I18n.t("inventory.void.status_voided"))
      expect([ summary("total"), summary("posted"), summary("voided") ]).to eq(%w[2 1 1])
    end

    it "sums this product's lines on a transfer and ignores other products' lines" do
      t = transfer!(north_wh, south_wh, lines: { product => [ 3, 4 ], other => 50 })
      visit_product(owner)

      expect(row(t.transfer_number).at_css("[data-stock-effect]").text).to include("7")
      expect(row(t.transfer_number).at_css("[data-stock-effect]").text).not_to include("50")
    end

    it "does not list a transfer that carries only other products" do
      transfer!(north_wh, south_wh, lines: { other => 5 })
      visit_product(owner)

      expect(numbers).to be_empty
    end
  end

  describe "limit and query cost" do
    let(:limit) { Inventory::ProductRecentDocuments::STOCK_TRANSFERS_LIMIT }

    it "shows the latest transfers only, with the full count and a note" do
      all = (1..(limit + 2)).map { |i| transfer!(north_wh, south_wh, on: Date.current - i) }
      visit_product(owner)

      expect(numbers).to eq(all.first(limit).map(&:transfer_number))
      expect(summary("total")).to eq((limit + 2).to_s)
      expect(section.at_css("[data-testid='stock-transfer-more']").text.squish)
        .to eq(I18n.t("inventory.products.show_layout.transfers.showing_latest", shown: limit, total: limit + 2))
    end

    it "shows no note when every transfer is listed" do
      transfer!(north_wh, south_wh)
      visit_product(owner)

      expect(section.at_css("[data-testid='stock-transfer-more']")).to be_nil
    end

    # Same warehouse mix at both sizes: the preloader's query shape (id = $1
    # vs id IN (…)) depends on how many distinct warehouses are loaded, not on
    # how many transfers there are.
    it "runs the same number of queries for two transfers as for many" do
      transfer!(central, north_wh)
      transfer!(south_wh, north_wh)
      sign_in owner
      get inventory_product_path(product) # warm-up

      count_queries = lambda do
        count = 0
        callback = ->(*, payload) { count += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:cached] }
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { get inventory_product_path(product) }
        count
      end

      one = count_queries.call
      (limit + 2).times { |i| transfer!(i.even? ? central : south_wh, north_wh, on: Date.current - i) }
      many = count_queries.call

      expect(many).to eq(one)
    end
  end

  describe "locales" do
    it "renders in Arabic, empty state included, with no missing translation" do
      visit_product(owner, locale: "ar")

      expect(response.body).to include('dir="rtl"').or include("dir='rtl'")
      expect(section.at_css("h2").text.squish).to eq("التحويلات بين الفروع")
      expect(section.text).to include(I18n.t("inventory.products.show_layout.transfers.empty", locale: :ar))
      expect(response.body).not_to include("translation missing")
    end

    it "renders in Arabic with rows" do
      transfer!(north_wh, south_wh)
      visit_product(owner, locale: "ar")

      expect(section.css("thead th").map { |th| th.text.squish })
        .to include(I18n.t("inventory.products.show_layout.transfers.from", locale: :ar),
                    I18n.t("inventory.products.show_layout.transfers.to", locale: :ar))
      expect(response.body).not_to include("translation missing")
    end

    it "renders in English, empty state included" do
      visit_product(owner, locale: "en")

      expect(section.at_css("h2").text.squish).to eq("Branch Transfers")
      expect(section.text).to include("This product has not been transferred between warehouses yet.")
      expect(response.body).not_to include("translation missing")
    end
  end

  describe "Manage Availability" do
    it "is not offered on the product page, even to a user who manages availability" do
      visit_product(owner)

      expect(page.css("[data-testid='manage-availability']")).to be_empty
      expect(response.body).not_to include(I18n.t("product_availability.card.manage"))
      expect(response.body).not_to include(I18n.t("product_availability.card.manage", locale: :ar))
    end

    it "stays reachable from its own page and from Edit" do
      sign_in owner
      get availability_inventory_product_path(product)
      expect(response).to have_http_status(:ok)
      get edit_inventory_product_path(product)
      expect(response).to have_http_status(:ok)
    end
  end
end
