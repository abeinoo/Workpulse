require "rails_helper"

# Phase 2: the warehouse page's Products tab — list, add (bulk), edit,
# deactivate (dependency summary + reason) and reactivate, all through
# Inventory::ProductAvailabilityManager. The UI hides what a user may not do;
# these specs also check the server refuses it.
RSpec.describe "Warehouse Products tab (product availability)", type: :request do
  let(:business)  { create(:business) }
  let(:other)     { create(:business) }
  let!(:owner)    { create(:user, :owner, business: business) }
  let!(:central)  { business.warehouses.create!(name: "Main Warehouse", kind: "central") }
  let!(:second)   { business.warehouses.create!(name: "Second WH", kind: "central") }
  let!(:shampoo)  { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10) }
  let!(:mask)     { business.products.create!(name: "Mask", sku: "MK-1", initial_cost_price: 4, average_cost_price: 4) }
  let!(:towel)    { business.products.create!(name: "Towel", sku: "TW-1", initial_cost_price: 2, average_cost_price: 2, track_inventory: false) }

  let(:manager)   { Inventory::ProductAvailabilityManager.new(actor: owner) }

  def add!(product, warehouse, **settings)
    expect(manager.add_many(warehouse_id: warehouse.id, items: [ { product_id: product.id, **settings } ])).to be_ok
    ProductWarehouseSetting.find_by!(product: product, warehouse: warehouse)
  end

  def stock!(product, warehouse, qty)
    InventoryMovement.create!(business: business, product: product, warehouse: warehouse, direction: :in,
                              quantity: qty, unit_cost: 1, reason: :adjustment, occurred_on: Date.current)
  end

  def snapshot = ProductWarehouseSetting.order(:id).pluck(:id, :product_id, :warehouse_id, :status, :low_stock_level, :reorder_quantity,
                                                          :receive_low_stock_notification)

  let(:viewer)          { user_with_stock_permissions(business, :view_inventory, name: "Viewer") }
  let(:avail_manager)   { user_with_stock_permissions(business, :view_inventory, :manage_product_availability, name: "Availability") }
  # manage_product_availability, assigned to the central warehouse only.
  let(:scoped_manager) do
    avail_manager.tap { |u| u.assigned_warehouses << central }
  end

  describe "index (the Products tab)" do
    before { sign_in owner }

    it "lists Active and Inactive rows with their own settings, never Not Configured products" do
      add!(shampoo, central, low_stock_level: 5, reorder_quantity: 20)
      add!(mask, central).then { |row| manager.deactivate(setting_id: row.id, reason: "Discontinued here") }
      ProductWarehouseSetting.create!(product: towel, warehouse: second) # untracked: pre-existing row (no new ones now)
      stock!(shampoo, central, 3)

      get inventory_warehouse_product_availabilities_path(central)

      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).to include("Shampoo", "Mask", "Discontinued here")
      expect(body).not_to include("Towel") # configured in another warehouse only
      # A central warehouse includes products by default: Active = Included, Inactive = Excluded.
      expect(body).to include(%(data-availability-state="included"), %(data-availability-state="excluded"))
      expect(body).to include("Low stock") # 3 on hand <= 5
      expect(body).to include(%(data-status-filter="active"))
    end

    it "filters by status and searches by name or SKU" do
      add!(shampoo, central)
      add!(mask, central).then { |row| manager.deactivate(setting_id: row.id, reason: "x") }

      get inventory_warehouse_product_availabilities_path(central, status: "inactive")
      expect(response.body).to include("Mask")
      expect(response.body).not_to include(">Shampoo<")

      get inventory_warehouse_product_availabilities_path(central, q: "sh-1")
      expect(response.body).to include("Shampoo")
      expect(response.body).not_to include(">Mask<")
    end

    it "shows an untracked product without low-stock settings and no low-stock badge" do
      ProductWarehouseSetting.create!(product: towel, warehouse: central) # pre-existing row (no new ones now)
      get inventory_warehouse_product_availabilities_path(central)
      expect(response.body).to include(I18n.t("product_availability.untracked"))
      expect(response.body).not_to include(">Low stock<")
    end

    it "explains that every product is included here by default (no 'not added' warning)" do
      stock!(mask, central, 4)
      get inventory_warehouse_product_availabilities_path(central)
      expect(response.body).to include(I18n.t("product_availability.index.included_by_default"))
      expect(response.body).not_to include(%(data-testid="unconfigured-with-stock"))
      expect(response.body).to include(I18n.t("product_availability.index.empty_title"))
    end

    it "an inactive warehouse explains that nothing can be added" do
      second.update!(status: "inactive")
      get inventory_warehouse_product_availabilities_path(second)
      expect(response.body).to include(I18n.t("product_availability.index.inactive_warehouse"))
      expect(response.body).not_to include(%(data-testid="add-products"))
    end
  end

  describe "permissions" do
    it "a viewer sees the tab but no actions, and the server refuses every change" do
      row = add!(shampoo, central)
      sign_in viewer

      get inventory_warehouse_product_availabilities_path(central)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Shampoo")
      expect(response.body).not_to include(%(data-testid="add-products"))
      expect(response.body).not_to include(deactivation_inventory_warehouse_product_availability_path(central, row))

      before = snapshot
      post inventory_warehouse_product_availabilities_path(central), params: { items: { mask.id => { selected: "1" } } }
      expect(response).to redirect_to(root_path)
      patch inventory_warehouse_product_availability_path(central, row), params: { product_warehouse_setting: { low_stock_level: 9 } }
      expect(response).to redirect_to(root_path)
      post deactivate_inventory_warehouse_product_availability_path(central, row), params: { reason: "x" }
      expect(response).to redirect_to(root_path)
      get new_inventory_warehouse_product_availability_path(central)
      expect(response).to redirect_to(root_path)
      patch availability_settings_inventory_product_path(mask), params: { warehouse_id: central.id, product_warehouse_setting: { low_stock_level: 1 } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(I18n.t("product_availability.errors.not_authorized"))
      expect(snapshot).to eq(before)
    end

    it "a warehouse-scoped manager cannot reach another warehouse's tab or rows" do
      foreign_row = add!(shampoo, second)
      sign_in scoped_manager

      get inventory_warehouse_product_availabilities_path(second)
      expect(response).to have_http_status(:not_found)
      # (A 404 response sets no session cookie: sign in again before each request.)
      sign_in scoped_manager
      post inventory_warehouse_product_availabilities_path(second), params: { items: { mask.id => { selected: "1" } } }
      expect(response).to have_http_status(:not_found)
      # A row of the other warehouse addressed through the reachable one.
      sign_in scoped_manager
      post deactivate_inventory_warehouse_product_availability_path(central, foreign_row), params: { reason: "x" }
      expect(response).to have_http_status(:not_found)
      sign_in scoped_manager
      post availability_exclusion_inventory_product_path(mask), params: { warehouse_id: second.id, reason: "x" }
      expect(response).to have_http_status(:not_found)
      expect(foreign_row.reload).to be_status_active
      expect(ProductWarehouseSetting.where(warehouse: second, product: mask)).to be_empty
    end

    it "another business's warehouse and rows are not found" do
      foreign_wh = other.warehouses.create!(name: "Foreign WH")
      sign_in owner
      get inventory_warehouse_product_availabilities_path(foreign_wh)
      expect(response).to have_http_status(:not_found)
      sign_in owner
      post inventory_warehouse_product_availabilities_path(foreign_wh), params: { items: { shampoo.id => { selected: "1" } } }
      expect(response).to have_http_status(:not_found)
      expect(ProductWarehouseSetting.count).to eq(0)
    end

    it "a product of another business cannot be added to this warehouse" do
      foreign_product = other.products.create!(name: "Foreign", sku: "FX-1", initial_cost_price: 1, average_cost_price: 1)
      sign_in owner
      post inventory_warehouse_product_availabilities_path(central), params: { items: { foreign_product.id => { selected: "1" } } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(I18n.t("product_availability.errors.invalid_product"))
      expect(ProductWarehouseSetting.count).to eq(0)
    end
  end

  describe "adding products (bulk)" do
    before { sign_in avail_manager }

    it "lists Not Configured candidates, and with 'All products' shows configured ones disabled with their state" do
      add!(shampoo, central)
      get new_inventory_warehouse_product_availability_path(central)
      expect(response.body).to include("Mask")
      expect(response.body).not_to include(%(data-testid="candidate-#{shampoo.id}"))

      get new_inventory_warehouse_product_availability_path(central, filter: "all")
      expect(response.body).to include(%(data-testid="candidate-#{shampoo.id}"), I18n.t("product_availability.add.already_active"))
      expect(response.body).not_to include(%(name="items[#{shampoo.id}][selected]"))
    end

    it "the 'with stock here' filter lists Not Configured products holding stock" do
      stock!(mask, central, 2)
      get new_inventory_warehouse_product_availability_path(central, filter: "with_stock")
      expect(response.body).to include(%(data-testid="candidate-#{mask.id}"))
      expect(response.body).not_to include(%(data-testid="candidate-#{shampoo.id}"))
    end

    it "adds only the ticked products, each with its own settings, audited, in this warehouse only" do
      post inventory_warehouse_product_availabilities_path(central), params: { items: {
        shampoo.id => { selected: "1", low_stock_level: "5", reorder_quantity: "12", receive_low_stock_notification: "0" },
        mask.id    => { selected: "1", low_stock_level: "2", reorder_quantity: "0", receive_low_stock_notification: "1" },
        towel.id   => { low_stock_level: "0" } # not ticked
      } }

      expect(response).to redirect_to(inventory_warehouse_product_availabilities_path(central))
      expect(flash[:notice]).to eq(I18n.t("product_availability.flash.added", count: 2, warehouse: "Main Warehouse"))
      rows = ProductWarehouseSetting.order(:product_id).map { |r| [ r.product_id, r.warehouse_id, r.status, r.low_stock_level, r.reorder_quantity, r.receive_low_stock_notification ] }
      expect(rows).to contain_exactly([ shampoo.id, central.id, "active", 5, 12, false ], [ mask.id, central.id, "active", 2, 0, true ])
      expect(AuditLog.where(action: "availability_add", actor: avail_manager).count).to eq(2)
    end

    it "reports products that were already configured as skipped — an Inactive one is never reactivated" do
      add!(mask, central).then { |row| manager.deactivate(setting_id: row.id, reason: "Gone") }
      post inventory_warehouse_product_availabilities_path(central), params: { items: {
        shampoo.id => { selected: "1" }, mask.id => { selected: "1" }
      } }

      expect(flash[:notice]).to include(I18n.t("product_availability.flash.added", count: 1, warehouse: "Main Warehouse"))
      expect(flash[:notice]).to include("Mask (Inactive)")
      expect(ProductWarehouseSetting.find_by!(product: mask)).to be_status_inactive
    end

    it "refuses the whole batch when one row is invalid, naming that product, and keeps the user's input" do
      post inventory_warehouse_product_availabilities_path(central), params: { items: {
        shampoo.id => { selected: "1", low_stock_level: "5" },
        mask.id    => { selected: "1", low_stock_level: "-1" }
      } }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Mask: #{I18n.t('product_availability.errors.invalid_quantity')}")
      kept = Nokogiri::HTML(response.body).at_css("input[name='items[#{shampoo.id}][selected]']")
      expect(kept["checked"]).to eq("checked")
      expect(ProductWarehouseSetting.count).to eq(0)
      expect(AuditLog.where(action: "availability_add")).to be_empty
    end

    it "refuses low-stock settings on an untracked product" do
      post inventory_warehouse_product_availabilities_path(central), params: { items: { towel.id => { selected: "1", low_stock_level: "3" } } }
      expect(response.body).to include("Towel: #{I18n.t('product_availability.errors.untracked_product')}")
      expect(ProductWarehouseSetting.count).to eq(0)
    end

    it "asks for a selection when nothing is ticked" do
      post inventory_warehouse_product_availabilities_path(central), params: { items: { shampoo.id => { low_stock_level: "1" } } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(I18n.t("product_availability.errors.no_items"))
    end
  end

  describe "editing settings" do
    before { sign_in avail_manager }

    it "saves this warehouse's settings and audits the change" do
      row = add!(shampoo, central, low_stock_level: 1, reorder_quantity: 1)
      patch inventory_warehouse_product_availability_path(central, row),
            params: { product_warehouse_setting: { low_stock_level: "4.5", reorder_quantity: "10", receive_low_stock_notification: "0" } }
      expect(response).to redirect_to(inventory_warehouse_product_availabilities_path(central))
      expect(row.reload).to have_attributes(low_stock_level: 4.5, reorder_quantity: 10, receive_low_stock_notification: false)
      expect(AuditLog.where(auditable: row, action: "availability_update").count).to eq(1)
    end

    it "re-renders with the reason when a value is invalid, and changes nothing" do
      row = add!(shampoo, central, low_stock_level: 1)
      patch inventory_warehouse_product_availability_path(central, row),
            params: { product_warehouse_setting: { low_stock_level: "-3", reorder_quantity: "0", receive_low_stock_notification: "1" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Shampoo: #{I18n.t('product_availability.errors.invalid_quantity')}")
      expect(row.reload.low_stock_level).to eq(1)
    end

    it "an untracked product's form has no threshold fields" do
      row = ProductWarehouseSetting.create!(product: towel, warehouse: central) # pre-existing row
      get edit_inventory_warehouse_product_availability_path(central, row)
      expect(response.body).to include(I18n.t("product_availability.edit.untracked"))
      expect(response.body).not_to include("product_warehouse_setting[low_stock_level]")
    end

    it "an Inactive row cannot be edited" do
      row = add!(shampoo, central)
      manager.deactivate(setting_id: row.id, reason: "x")
      get edit_inventory_warehouse_product_availability_path(central, row)
      expect(response).to redirect_to(inventory_warehouse_product_availabilities_path(central))
      patch inventory_warehouse_product_availability_path(central, row), params: { product_warehouse_setting: { low_stock_level: "9" } }
      expect(response.body).to include(I18n.t("product_availability.errors.inactive"))
      expect(row.reload.low_stock_level).to eq(0)
    end
  end

  describe "deactivating and reactivating" do
    before { sign_in avail_manager }

    it "shows the dependency summary and what will be blocked before anything changes" do
      row = add!(shampoo, central)
      stock!(shampoo, central, 7)
      get deactivation_inventory_warehouse_product_availability_path(central, row)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("product_availability.deactivation.blocks_incoming"),
                                       I18n.t("product_availability.deactivation.allows_outgoing"),
                                       I18n.t("product_availability.deactivation.has_dependencies"))
      expect(response.body).to match(%r{<dt>On hand</dt>\s*<dd>7</dd>})
      expect(row.reload).to be_status_active
    end

    it "requires a reason and does not pretend to have deactivated without one" do
      row = add!(shampoo, central)
      post deactivate_inventory_warehouse_product_availability_path(central, row), params: { reason: "  " }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(I18n.t("product_availability.errors.reason_required"))
      expect(response.body).not_to include(I18n.t("product_availability.flash.deactivated", product: "Shampoo", warehouse: "Main Warehouse"))
      expect(row.reload).to be_status_active
    end

    it "deactivates with the reason (audited, settings kept) and reactivates with the same settings" do
      row = add!(shampoo, central, low_stock_level: 3, reorder_quantity: 9)
      post deactivate_inventory_warehouse_product_availability_path(central, row), params: { reason: "Not sold here" }
      expect(response).to redirect_to(inventory_warehouse_product_availabilities_path(central))
      expect(flash[:notice]).to eq(I18n.t("product_availability.flash.deactivated", product: "Shampoo", warehouse: "Main Warehouse"))
      expect(row.reload).to have_attributes(status: "inactive", status_reason: "Not sold here", status_changed_by_id: avail_manager.id)
      expect(AuditLog.where(auditable: row, action: "availability_deactivate").count).to eq(1)

      post reactivate_inventory_warehouse_product_availability_path(central, row)
      expect(flash[:notice]).to eq(I18n.t("product_availability.flash.reactivated", product: "Shampoo", warehouse: "Main Warehouse"))
      expect(row.reload).to have_attributes(status: "active", low_stock_level: 3, reorder_quantity: 9)
    end

    it "a second deactivation of the same row is refused, not reported as success" do
      row = add!(shampoo, central)
      manager.deactivate(setting_id: row.id, reason: "first")
      post deactivate_inventory_warehouse_product_availability_path(central, row), params: { reason: "second" }
      expect(flash[:alert]).to eq("Shampoo: #{I18n.t('product_availability.errors.already_inactive')}")
      expect(row.reload.status_reason).to eq("first")
    end

    it "returns to the product Edit section only when asked, never to an arbitrary URL" do
      row = add!(shampoo, central)
      post deactivate_inventory_warehouse_product_availability_path(central, row), params: { reason: "x", return_to: "product_edit" }
      expect(response).to redirect_to(edit_inventory_product_path(shampoo, anchor: "availability"))

      post reactivate_inventory_warehouse_product_availability_path(central, row), params: { return_to: "https://evil.example" }
      expect(response).to redirect_to(inventory_warehouse_product_availabilities_path(central))
    end
  end

  describe "in Arabic" do
    it "renders the tab right-to-left with Arabic labels" do
      add!(shampoo, central)
      owner.update!(preferred_locale: "ar")
      sign_in owner
      get inventory_warehouse_product_availabilities_path(central)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('dir="rtl"', "المنتجات في هذا المستودع", "نشط")
      expect(response.body).not_to include("translation missing")
    end
  end
end
