require "rails_helper"

# Product Edit, 2026-11-20: "Track stock quantity" stays (product-level);
# the product-wide low-stock level / reorder quantity / alert / total-alert
# fields are gone from the form (per-warehouse settings replace them) and
# their stored legacy values are left untouched. Untracked products show no
# warehouse cards and get no new availability rows; tracking cannot be turned
# off while stock or open documents remain. Unclassified warehouses are not
# included by default.
RSpec.describe "Product tracking and retired product-wide fields", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:central) { business.warehouses.create!(name: "Central WH", kind: "central") }
  let!(:branch_wh) { business.warehouses.create!(name: "Nasr City", kind: "branch", branch: create(:branch, business: business)) }
  let!(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 1, average_cost_price: 1,
                              low_stock_level: 7, reorder_quantity: 30, reorder_level: 4, receive_low_stock_notification: false)
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
      form = doc.at_css("form#product-form")
      expect(form.at_css("input[type='checkbox'][name='product[track_inventory]']")).to be_present
      expect(form.text).to include("Track stock quantity")
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

    it "ignores crafted product-wide values: the legacy values stay exactly as stored" do
      update_product(name: "Shampoo Pro", low_stock_level: 99, reorder_quantity: 99, reorder_level: 99, receive_low_stock_notification: "1")
      expect(response).to redirect_to(inventory_product_path(product))
      expect(product.reload.attributes.values_at("name", "low_stock_level", "reorder_quantity", "reorder_level", "receive_low_stock_notification"))
        .to eq([ "Shampoo Pro", 7, 30, 4, false ])
    end
  end

  describe "legacy product-wide values" do
    def no_transfer_ui!
      expect(response.body).not_to include("pending-transfer", "legacy-total-alert-active", "legacy-values")
      expect(response.body).not_to include(I18n.t("product_availability.reconciliation.legacy.transfers.to_create"))
    end

    it "Edit has no transfer UI: the central card is a normal editable card from its own settings (never legacy values)" do
      product.update_columns(receive_low_stock_notification: true)
      get edit_inventory_product_path(product)
      no_transfer_ui!
      expect(doc.at_css("#pws-#{central.id}-low")["value"]).to eq("0") # no central row yet: its own (default) settings
      expect(doc.at_css("#pws-#{central.id}-reorder")["value"]).to eq("0")
      expect(doc.at_css("[data-testid='save-#{central.id}']")).to be_present
      expect(ProductWarehouseSetting.count).to eq(0) # opening the page writes nothing
    end

    it "after the backfill the central card shows the persisted 7 / 30 in its normal inputs" do
      preview = Inventory::LegacyCentralSettingsBackfill.new(business).dry_run
      Inventory::LegacyCentralSettingsBackfill.new(business, actor: owner)
                                              .apply!(expected_central_id: preview.central.id, expected_count: preview.to_create_count)
      expect(ProductWarehouseSetting.find_by!(warehouse: central)).to have_attributes(low_stock_level: 7, reorder_quantity: 30)
      get edit_inventory_product_path(product)
      no_transfer_ui!
      expect(doc.at_css("#pws-#{central.id}-low")["value"]).to eq("7")
      expect(doc.at_css("#pws-#{central.id}-reorder")["value"]).to eq("30")
    end

    it "the reconciliation report (not the Edit page) lists them with their transfer status" do
      product.update_columns(track_inventory: false)
      get inventory_availability_reconciliation_path
      expect(doc.at_css("[data-testid='legacy-transfer-#{product.id}']").text)
        .to include(I18n.t("product_availability.reconciliation.legacy.transfers.untracked"))

      product.update_columns(track_inventory: true)
      get inventory_availability_reconciliation_path
      expect(doc.at_css("[data-testid='legacy-transfer-#{product.id}']").text)
        .to include(I18n.t("product_availability.reconciliation.legacy.transfers.to_create"))
      expect(doc.at_css("[data-testid='transfer-summary']").text)
        .to include(I18n.t("product_availability.reconciliation.legacy.transfer_summary", transferred: 0, pending: 1, exceptions: 0))
      expect(ProductWarehouseSetting.count).to eq(0)
      expect(product.reload.attributes.values_at("low_stock_level", "reorder_quantity", "reorder_level")).to eq([ 7, 30, 4 ])
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
