require "rails_helper"

# Phase 2: the product page's read-only Warehouse Availability summary, and
# the product form without per-warehouse rows (availability is written only by
# Inventory::ProductAvailabilityManager). Also BUG-068 (parent product page).
RSpec.describe "Product page — Warehouse Availability card", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:central) { business.warehouses.create!(name: "Main Warehouse", kind: "central") }
  let!(:other_wh) { business.warehouses.create!(name: "Second WH", kind: "central") }
  let!(:product) do
    # Legacy product-wide values (historical central warehouse) — never shown
    # as another warehouse's settings.
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10,
                              low_stock_level: 77, reorder_quantity: 88)
  end
  let(:manager) { Inventory::ProductAvailabilityManager.new(actor: owner) }

  def add!(warehouse, **settings)
    expect(manager.add_many(warehouse_id: warehouse.id, items: [ { product_id: product.id, **settings } ])).to be_ok
    ProductWarehouseSetting.find_by!(product: product, warehouse: warehouse)
  end

  def stock!(warehouse, qty, item: product)
    InventoryMovement.create!(business: business, product: item, warehouse: warehouse, direction: :in,
                              quantity: qty, unit_cost: 1, reason: :adjustment, occurred_on: Date.current)
  end

  def card_row(warehouse)
    Nokogiri::HTML(response.body).at_css(%([data-testid="availability-warehouse-#{warehouse.id}"]))
  end

  describe "the card" do
    before { sign_in owner }

    it "shows each warehouse's own state and settings, and no legacy value for a warehouse without its own settings" do
      add!(central, low_stock_level: 5, reorder_quantity: 0)
      stock!(central, 4)
      stock!(other_wh, 2) # stock, but never added there

      get inventory_product_path(product)

      expect(response).to have_http_status(:ok)
      main_row = card_row(central)
      expect(main_row.at_css("[data-availability-state]")["data-availability-state"]).to eq("included")
      expect(main_row.text).to include("Low stock", "5", I18n.t("product_availability.no_suggestion"))

      other_row = card_row(other_wh)
      # Included by default (central warehouse, no row): defaults, never the legacy product values.
      expect(other_row.at_css("[data-availability-state]")["data-availability-state"]).to eq("included")
      expect(other_row.text).to include(I18n.t("product_availability.card.default_settings_hint"))
      expect(other_row.text).not_to include("77")
      expect(other_row.text).not_to include("88")
    end

    it "shows an Inactive warehouse with its reason, read-only" do
      row = add!(central)
      manager.deactivate(setting_id: row.id, reason: "Moved to Second WH")
      get inventory_product_path(product)
      expect(card_row(central).text).to include("Moved to Second WH")
      expect(card_row(central).css("form, button")).to be_empty
    end

    it "is read-only and links to the Edit page's availability section" do
      add!(central)
      get inventory_product_path(product)
      section = Nokogiri::HTML(response.body).at_css(%([data-testid="warehouse-availability"]))
      expect(section.css("form")).to be_empty
      expect(section.at_css(%([data-testid="manage-availability"]))["href"]).to eq(edit_inventory_product_path(product, anchor: "availability"))
    end

    it "renders in Arabic" do
      add!(central)
      owner.update!(preferred_locale: "ar")
      get inventory_product_path(product)
      expect(response.body).to include("توفر المنتج في المستودعات", "مُدرج")
      expect(response.body).not_to include("translation missing")
    end
  end

  describe "visibility" do
    it "a viewer sees the card without any action" do
      add!(central)
      sign_in user_with_stock_permissions(business, :view_inventory, name: "Viewer")
      get inventory_product_path(product)
      expect(card_row(central)).to be_present
      expect(response.body).not_to include(%(data-testid="manage-availability"))
    end

    it "a warehouse-scoped user sees only their warehouses" do
      add!(central)
      add!(other_wh)
      user = user_with_stock_permissions(business, :view_inventory, :manage_product_availability, name: "Scoped")
      user.assigned_warehouses << central
      sign_in user
      get inventory_product_path(product)
      expect(card_row(central)).to be_present
      expect(card_row(other_wh)).to be_nil
      expect(response.body).not_to include("Second WH")
    end
  end

  describe "the product form" do
    before { sign_in owner }

    it "has no per-warehouse rows inside the product form" do
      add!(central, low_stock_level: 3)
      get edit_inventory_product_path(product)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("product_warehouse_settings_attributes")
      expect(Nokogiri::HTML(response.body).css("form#product-form [data-testid^='availability-card']")).to be_empty

      get new_inventory_product_path
      expect(response.body).not_to include("product_warehouse_settings_attributes")
      expect(response.body).to include(ERB::Util.html_escape(I18n.t("product_availability.form.managed_after_create")))
    end

    it "refuses a submission that still carries per-warehouse rows, and changes nothing" do
      row = add!(central, low_stock_level: 3)
      patch inventory_product_path(product), params: { product: {
        name: "Renamed", sku: product.sku,
        product_warehouse_settings_attributes: { "0" => { id: row.id, warehouse_id: central.id, low_stock_level: 9 } }
      } }
      expect(response).to redirect_to(root_path)
      expect(product.reload.name).to eq("Shampoo")
      expect(row.reload.low_stock_level).to eq(3)

      expect {
        post inventory_products_path, params: { product: {
          name: "Mask", sku: "MK-1", initial_cost_price: 1,
          product_warehouse_settings_attributes: { "0" => { warehouse_id: central.id, low_stock_level: 2 } }
        } }
      }.not_to change { [ Product.count, ProductWarehouseSetting.count ] }
      expect(response).to redirect_to(root_path)
    end

    it "still saves an ordinary product edit and leaves availability untouched" do
      row = add!(central, low_stock_level: 3)
      patch inventory_product_path(product), params: { product: { name: "Shampoo Pro", sku: product.sku } }
      expect(response).to redirect_to(inventory_product_path(product))
      expect(product.reload.name).to eq("Shampoo Pro")
      expect(row.reload.low_stock_level).to eq(3)
    end
  end

  describe "BUG-068: a parent product with children" do
    let!(:parent) { business.products.create!(name: "Shampoo Family", sku: "FAM", initial_cost_price: 1, average_cost_price: 1) }
    let!(:child)  { business.products.create!(name: "Shampoo 1L", sku: "FAM-1", initial_cost_price: 1, average_cost_price: 1, parent_product: parent) }

    before do
      stock!(central, 6, item: child)
      sign_in owner
    end

    it "renders the parent page and its children list with the children's stock" do
      get inventory_product_path(parent)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Shampoo 1L")

      get children_inventory_product_path(parent)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Shampoo 1L")
    end
  end
end
