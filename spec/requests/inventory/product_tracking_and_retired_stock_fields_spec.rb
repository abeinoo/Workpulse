require "rails_helper"

# Product Edit: "Track stock quantity" stays (product-level). Low-stock
# threshold, reorder quantity and the low-stock notification are per warehouse
# only — the product has none: no field on the form (not even read-only), no
# parameter accepted, and a warehouse without its own setting never falls back
# to the stale values still stored in the retired product columns. Untracked
# products show no warehouse cards and get no new availability rows; tracking
# cannot be turned off while stock or open documents remain. Unclassified
# warehouses are not included by default.
RSpec.describe "Product tracking and retired product-wide fields", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:central) { business.warehouses.create!(name: "Central WH", kind: "central") }
  let!(:branch_wh) { business.warehouses.create!(name: "Nasr City", kind: "branch", branch: create(:branch, business: business)) }
  # Stale values in the retired product-level columns, as existing databases still hold.
  let!(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 1, average_cost_price: 1)
            .tap { |p| write_retired_product_stock_columns!(p, low_stock_level: 7, reorder_quantity: 30, reorder_level: 4,
                                                            receive_low_stock_notification: false) }
  end
  let(:stale_columns) do
    { "low_stock_level" => 7, "reorder_quantity" => 30, "reorder_level" => 4, "receive_low_stock_notification" => false }
  end
  let(:manager) { Inventory::ProductAvailabilityManager.new(actor: owner) }

  def doc = Nokogiri::HTML(response.body)

  def stock!(warehouse, qty, direction: :in)
    InventoryMovement.create!(business: business, product: product, warehouse: warehouse, direction: direction,
                              quantity: qty, unit_cost: 1, reason: :adjustment, occurred_on: Date.current)
  end

  def update_product(attrs) = patch inventory_product_path(product), params: { product: { name: product.name, sku: product.sku }.merge(attrs) }

  before { sign_in owner }

  describe "the form" do
    it "keeps Track stock quantity and no longer shows the product-wide replenishment fields" do
      get edit_inventory_product_path(product)
      # In the Inventory Tracking section (outside the <form> element), bound to the product form.
      checkbox = doc.at_css("input[type='checkbox'][name='product[track_inventory]']")
      expect(checkbox["form"]).to eq("product-form")
      expect(doc.at_css("[data-testid='inventory-tracking-section']").text).to include("Track stock quantity")
      %w[low_stock_level reorder_quantity receive_low_stock_notification reorder_level].each do |field|
        expect(doc.css("[name='product[#{field}]']")).to be_empty
      end
    end

    it "in Arabic too" do
      owner.update!(preferred_locale: "ar")
      get edit_inventory_product_path(product)
      expect(response.body).to include("تتبع كمية المخزون")
      expect(response.body).not_to include("translation missing")
    end

    it "ignores crafted product-wide values: nothing is written to the retired columns or to any warehouse" do
      update_product(name: "Shampoo Pro", low_stock_level: 99, reorder_quantity: 99, reorder_level: 99, receive_low_stock_notification: "1")
      expect(response).to redirect_to(inventory_product_path(product))
      expect(product.reload.name).to eq("Shampoo Pro")
      expect(retired_product_stock_columns(product)).to eq(stale_columns)
      expect(ProductWarehouseSetting.count).to eq(0)
    end

    it "shows no product-level Low Stock or Reorder field — editable or read-only — on Edit, New or Show" do
      [ edit_inventory_product_path(product), new_inventory_product_path, inventory_product_path(product) ].each do |path|
        get path
        expect(response).to have_http_status(:ok)
        expect(doc.css("[data-testid^='legacy-low-stock'], [data-testid^='legacy-reorder'], #product_legacy_low_stock_level, " \
                       "#product_legacy_reorder_quantity")).to be_empty
        expect(response.body).not_to include("(legacy, read-only)", "Reorder Level", "Receive Low Stock Notifications",
                                             "Legacy low-stock level", "Legacy reorder quantity")
      end
    end
  end

  describe "no fallback to the retired product-level values" do
    it "a warehouse without its own setting shows its defaults (0 / 0), never the stale product values" do
      get edit_inventory_product_path(product)
      expect(doc.at_css("#pws-#{central.id}-low")["value"]).to eq("0")
      expect(doc.at_css("#pws-#{central.id}-reorder")["value"]).to eq("0")
      expect(doc.at_css("#pws-#{branch_wh.id}-low")["value"]).to eq("0")
      expect(ProductWarehouseSetting.count).to eq(0) # opening the page writes nothing
    end

    it "each warehouse shows and keeps its own values; saving one card changes nothing else" do
      manager.add_many(warehouse_id: central.id, items: [ { product_id: product.id, low_stock_level: 3, reorder_quantity: 11 } ], source: "spec")
      manager.add_many(warehouse_id: branch_wh.id, items: [ { product_id: product.id, low_stock_level: 5, reorder_quantity: 2 } ], source: "spec")
      patch availability_settings_inventory_product_path(product), params: {
        warehouse_id: central.id, return_to: "product_edit",
        product_warehouse_setting: { low_stock_level: "12", reorder_quantity: "40" }
      }

      expect(ProductWarehouseSetting.find_by!(warehouse: central)).to have_attributes(low_stock_level: 12, reorder_quantity: 40)
      expect(ProductWarehouseSetting.find_by!(warehouse: branch_wh)).to have_attributes(low_stock_level: 5, reorder_quantity: 2)
      expect(retired_product_stock_columns(product)).to eq(stale_columns)
      get edit_inventory_product_path(product)
      expect(doc.at_css("#pws-#{central.id}-low")["value"]).to eq("12")
      expect(doc.at_css("#pws-#{branch_wh.id}-low")["value"]).to eq("5")
    end

    it "the product page's low-stock badge follows warehouse settings only" do
      stock!(central, 3)
      get inventory_product_path(product) # stale product threshold 7 ≥ 3 — ignored
      expect(response.body).not_to include(I18n.t("inventory.products.low_stock_badge"))

      manager.add_many(warehouse_id: central.id, items: [ { product_id: product.id, low_stock_level: 5, reorder_quantity: 0 } ], source: "spec")
      get inventory_product_path(product)
      expect(response.body).to include(I18n.t("inventory.products.low_stock_badge"))
    end

    it "the products list highlights stock as low only from a warehouse setting" do
      stock!(central, 3)
      get inventory_products_path
      row = doc.css("tr").find { |tr| tr.text.include?("SH-1") }
      expect(row.at_css(".badge-warning")).to be_nil

      manager.add_many(warehouse_id: central.id, items: [ { product_id: product.id, low_stock_level: 5, reorder_quantity: 0 } ], source: "spec")
      get inventory_products_path
      row = doc.css("tr").find { |tr| tr.text.include?("SH-1") }
      expect(row.at_css(".badge-warning")&.text&.strip).to eq("3")
    end
  end

  describe "turning tracking off" do
    it "is refused while the product holds stock, with the reason, and nothing changes" do
      stock!(branch_wh, 3)
      update_product(track_inventory: "0")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("stock in 1 warehouse")
      expect(product.reload).to be_track_inventory
    end

    it "is refused while open inventory documents reference it" do
      issue = business.stock_issues.build(warehouse: branch_wh, branch: branch_wh.branch, issued_on: Date.current, created_by: owner)
      issue.items.build(product: product, quantity: 1)
      issue.save!
      update_product(track_inventory: "0")
      expect(response.body).to include("1 open stock issue line")
      expect(product.reload).to be_track_inventory
    end

    it "is allowed with no stock and no open documents: the cards are hidden, existing rows and movements kept" do
      manager.save_settings(product_id: product.id, warehouse_id: branch_wh.id, low_stock_level: 2, reorder_quantity: 0)
      stock!(branch_wh, 3)
      stock!(branch_wh, 3, direction: :out) # history, balance back to zero
      update_product(track_inventory: "0")
      expect(product.reload).not_to be_track_inventory
      expect(ProductWarehouseSetting.sole.low_stock_level).to eq(2)
      expect(InventoryMovement.where(product: product).count).to eq(2)

      get edit_inventory_product_path(product)
      expect(doc.at_css("[data-testid='untracked-notice']")).to be_present
      expect(doc.css("[data-testid^='availability-card']")).to be_empty
    end

    it "an untracked product gets no new availability rows" do
      product.update!(track_inventory: false)
      expect(manager.save_settings(product_id: product.id, warehouse_id: branch_wh.id, low_stock_level: 0, reorder_quantity: 0).error).to eq(:untracked_product)
      expect(manager.exclude(product_id: product.id, warehouse_id: central.id, reason: "x").error).to eq(:untracked_product)
      expect(manager.add_many(warehouse_id: central.id, items: [ { product_id: product.id } ]).error).to eq(:untracked_product)
      expect(ProductWarehouseSetting.count).to eq(0)
    end

    it "turning it on again shows every warehouse with its own kept settings, never the product-wide values" do
      manager.save_settings(product_id: product.id, warehouse_id: branch_wh.id, low_stock_level: 2, reorder_quantity: 0)
      product.update!(track_inventory: false)
      update_product(track_inventory: "1")
      expect(product.reload).to be_track_inventory

      get edit_inventory_product_path(product)
      expect(doc.at_css("#pws-#{branch_wh.id}-low")["value"]).to eq("2")
      expect(doc.at_css("#pws-#{central.id}-low")["value"]).to eq("0") # its own settings, never the legacy 7
      expect(ProductWarehouseSetting.count).to eq(1) # nothing created by viewing
    end
  end

  describe "stock counts" do
    it "leave out an untracked product with no stock there, but count one that still holds stock" do
      chair = business.products.create!(name: "Chair", sku: "CH-1", initial_cost_price: 1, average_cost_price: 1, track_inventory: false)
      lamp  = business.products.create!(name: "Lamp", sku: "LM-1", initial_cost_price: 1, average_cost_price: 1, track_inventory: false)
      InventoryMovement.create!(business: business, product: lamp, warehouse: central, direction: :in, quantity: 1,
                                unit_cost: 1, reason: :adjustment, occurred_on: Date.current)
      result = Inventory::StockCountCreator.new(actor: owner, warehouse_id: central.id, counted_on: Date.current).call
      names = result.count.items.map { |i| i.product.name }
      expect(names).to include("Shampoo", "Lamp")
      expect(names).not_to include(chair.name)
    end
  end

  describe "unclassified warehouses" do
    it "are not included by default: no card without a row, an existing row shown read-only for review, nothing created" do
      unclassified = business.warehouses.create!(name: "Old store")
      get edit_inventory_product_path(product)
      expect(doc.at_css("[data-testid='availability-card-#{unclassified.id}']")).to be_nil
      expect(unclassified.availability_included_by_default?).to be(false)

      ProductWarehouseSetting.create!(product: product, warehouse: unclassified, low_stock_level: 3, reorder_quantity: 1)
      get edit_inventory_product_path(product)
      card = doc.at_css("[data-testid='availability-card-#{unclassified.id}']")
      expect(card.ancestors("[data-testid='availability-group-other']")).to be_present
      expect(card.css("input, form, button")).to be_empty
      expect(card.at_css("[data-testid='not-included-#{unclassified.id}']")).to be_present
      expect(manager.save_settings(product_id: product.id, warehouse_id: unclassified.id, low_stock_level: 9, reorder_quantity: 0).error)
        .to eq(:not_included_by_default)
      expect(manager.exclude(product_id: product.id, warehouse_id: unclassified.id, reason: "x").error).to eq(:not_included_by_default)
      expect(ProductWarehouseSetting.find_by!(warehouse: unclassified)).to have_attributes(status: "active", low_stock_level: 3)
    end
  end
end
