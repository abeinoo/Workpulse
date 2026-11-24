require "rails_helper"

# The product Edit page's inventory section: EVERY active warehouse (sales
# branches and central warehouses alike) has a card automatically (Included by
# default — no row needed), settings are
# edited in place, a checkbox excludes a branch (reason + dependency summary)
# and "Include again" undoes it. No "Add to warehouses" step exists. Every
# write goes through Inventory::ProductAvailabilityManager, separately from the
# product form.
RSpec.describe "Product Edit — availability per warehouse (included by default)", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }

  def sales_warehouse(name)
    business.warehouses.create!(name: name, kind: "branch", branch: create(:branch, business: business, name: "#{name} branch"))
  end

  let!(:nasr)    { sales_warehouse("Nasr City") }
  let!(:shubra)  { sales_warehouse("Shubra") }
  let!(:central) { business.warehouses.create!(name: "Central WH", kind: "central") }
  # Stale values in the retired product-level columns: never shown or used.
  let!(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
            .tap { |p| write_retired_product_stock_columns!(p, low_stock_level: 77, reorder_quantity: 88) }
  end
  let(:manager)  { Inventory::ProductAvailabilityManager.new(actor: owner) }

  # Edits products and manages availability.
  let(:editor) { user_with_stock_permissions(business, :view_inventory, :manage_products, :manage_product_availability, name: "Editor") }

  def stock!(warehouse, qty)
    InventoryMovement.create!(business: business, product: product, warehouse: warehouse, direction: :in,
                              quantity: qty, unit_cost: 1, reason: :adjustment, occurred_on: Date.current)
  end

  def doc = Nokogiri::HTML(response.body)
  def card(warehouse) = doc.at_css(%([data-testid="availability-card-#{warehouse.id}"]))
  def state(warehouse) = card(warehouse)["data-availability-card-state"]
  def snapshot = ProductWarehouseSetting.order(:id).pluck(:id, :warehouse_id, :status, :low_stock_level, :reorder_quantity, :receive_low_stock_notification)

  def save(warehouse, low:, reorder: "0", return_to: "product_edit")
    patch availability_settings_inventory_product_path(product), params: {
      warehouse_id: warehouse.id, return_to: return_to,
      product_warehouse_setting: { low_stock_level: low, reorder_quantity: reorder }
    }
  end

  def exclude(warehouse, reason: "Not sold here")
    post availability_exclusion_inventory_product_path(product), params: { warehouse_id: warehouse.id, return_to: "product_edit", reason: reason }
  end

  describe "the section" do
    before { sign_in editor }

    it "shows every active sales branch automatically as Included, with no row created and no Add step" do
      get edit_inventory_product_path(product)

      expect(response).to have_http_status(:ok)
      expect([ state(nasr), state(shubra) ]).to eq(%w[included included])
      expect(state(central)).to eq("included") # central too: included by default, nothing created
      expect(ProductWarehouseSetting.count).to eq(0)
      expect(response.body).not_to include("add-to-warehouses", "Add to warehouses", "add_to_warehouses")
      # Settings editable in place; the exclusion checkbox on the card.
      expect(card(nasr).at_css("#pws-#{nasr.id}-low")["value"]).to eq("0")
      expect(card(nasr).at_css("[data-testid='exclude-#{nasr.id}']")).to be_present
      expect(card(nasr).text).to include(I18n.t("product_availability.section.exclude_label"))
      # Never the product-level legacy value.
      expect(card(nasr).text).not_to include("77")
    end

    it "is outside the product form: no nested forms, notes and Save still submit the product form" do
      get edit_inventory_product_path(product)
      expect(doc.css("form form")).to be_empty
      product_form = doc.at_css("form#product-form")
      expect(product_form.css("[data-testid^='availability-card']")).to be_empty
      expect(doc.at_css("textarea#product_notes")["form"]).to eq("product-form")
      expect(doc.at_css("[data-testid='product-save']")["form"]).to eq("product-form")
    end

    it "does not list non-sales or inactive branch warehouses" do
      laundry = sales_warehouse("Laundry")
      laundry.branch.update_column(:branch_type, "laundry")
      closed = sales_warehouse("Closed")
      closed.update!(status: "inactive")

      get edit_inventory_product_path(product)
      expect(card(laundry)).to be_nil
      expect(card(closed)).to be_nil
    end

    it "keeps an existing Active central row's own settings, with the same controls as a branch" do
      manager.add_many(warehouse_id: central.id, items: [ { product_id: product.id, low_stock_level: 4 } ])
      get edit_inventory_product_path(product)
      expect(state(central)).to eq("included")
      expect(card(central).at_css("#pws-#{central.id}-low")["value"]).to eq("4")
      expect(card(central).at_css("[data-testid='exclude-#{central.id}']")).to be_present
    end

    it "shows on hand, reserved and Low stock from the branch's own threshold" do
      manager.save_settings(product_id: product.id, warehouse_id: nasr.id, low_stock_level: 5, reorder_quantity: 10)
      stock!(nasr, 3)
      get edit_inventory_product_path(product)
      expect(card(nasr).text).to include("Low stock", "3")
      expect(card(nasr).at_css("#pws-#{nasr.id}-reorder")["value"]).to eq("10")
    end

    it "shows no warehouse cards for an untracked product, only the explanation" do
      product.update!(track_inventory: false)
      get edit_inventory_product_path(product)
      expect(doc.at_css("[data-testid='untracked-notice']").text).to include("not tracked")
      expect(doc.css("[data-testid^='availability-card']")).to be_empty
    end

    it "keeps a legacy 'alerts off' choice visible and never shows the old checkbox" do
      manager.save_settings(product_id: product.id, warehouse_id: nasr.id, low_stock_level: 5, reorder_quantity: 0)
      ProductWarehouseSetting.find_by!(warehouse: nasr).update_column(:receive_low_stock_notification, false)
      get edit_inventory_product_path(product)
      expect(card(nasr).at_css("[data-testid='legacy-alerts-off-#{nasr.id}']")).to be_present
      expect(doc.at_css("#availability").to_html).not_to include("receive_low_stock_notification")
    end

    it "renders in Arabic, right-to-left, with the Arabic exclusion label and no missing translation" do
      editor.update!(preferred_locale: "ar")
      get edit_inventory_product_path(product)
      expect(response.body).to include('dir="rtl"', "توفر المنتج في المستودعات", "استبعاد المنتج من هذا المستودع", "مُدرج")
      expect(response.body).not_to include("translation missing")
    end

    it "escapes the excluding user's name and reason" do
      editor.update_columns(first_name: "<script>alert(1)</script>", last_name: "X")
      Inventory::ProductAvailabilityManager.new(actor: editor).exclude(product_id: product.id, warehouse_id: nasr.id, reason: "<b>bold</b>")
      get edit_inventory_product_path(product)
      note = card(nasr).at_css("[data-testid='inactive-reason']")
      expect(note.css("script, b")).to be_empty
      expect(note.text).to include("<script>alert(1)</script>", "<b>bold</b>")
    end
  end

  describe "central warehouses (same workflow as branches)" do
    before { sign_in editor }

    it "groups the cards by type only — every card has the same controls, and there is no Add action anywhere" do
      second_central = business.warehouses.create!(name: "Old Central", kind: "central")
      get edit_inventory_product_path(product)

      branches = doc.at_css("[data-testid='availability-group-branches']")
      centrals = doc.at_css("[data-testid='availability-group-central']")
      expect(branches.css("[data-testid^='availability-card']").map { |c| c["data-testid"] })
        .to contain_exactly("availability-card-#{nasr.id}", "availability-card-#{shubra.id}")
      expect(centrals.css("[data-testid^='availability-card']").map { |c| c["data-testid"] })
        .to eq([ "availability-card-#{central.id}", "availability-card-#{second_central.id}" ])
      [ nasr, central, second_central ].each do |w|
        expect(state(w)).to eq("included")
        expect(card(w).at_css("[data-testid='exclude-#{w.id}']")).to be_present
        expect(card(w).at_css("#pws-#{w.id}-low")["value"]).to eq("0") # defaults, never a legacy value
        expect(card(w).at_css("[data-testid='save-#{w.id}']")).to be_nil # saved by the page's one Save
      end
      expect(card(central).text).to include("Central")
      expect(card(central).text).not_to include("77")
      expect(response.body).not_to include("Add to this central warehouse", "availability_central")
      expect(ProductWarehouseSetting.count).to eq(0)
    end

    it "saves central settings directly (first save creates the row, audited) — independent of the branches" do
      save(nasr, low: "3")
      save(central, low: "40", reorder: "100")
      rows = ProductWarehouseSetting.order(:warehouse_id).to_h { |r| [ r.warehouse_id, [ r.low_stock_level, r.reorder_quantity ] ] }
      expect(rows).to eq(nasr.id => [ 3, 0 ], central.id => [ 40, 100 ])
      expect(AuditLog.where(action: "availability_add", actor: editor).count).to eq(2)
    end

    it "excludes and includes a central warehouse exactly like a branch" do
      exclude(central, reason: "Not stocked centrally")
      row = ProductWarehouseSetting.sole
      expect(row).to have_attributes(warehouse_id: central.id, status: "inactive", status_reason: "Not stocked centrally")
      get edit_inventory_product_path(product)
      expect(state(central)).to eq("excluded")

      post availability_inclusion_inventory_product_path(product), params: { warehouse_id: central.id, return_to: "product_edit" }
      expect(row.reload).to be_status_active
    end

    it "never reactivates an existing Inactive central row by saving settings" do
      manager.add_many(warehouse_id: central.id, items: [ { product_id: product.id, low_stock_level: 4 } ])
      row = ProductWarehouseSetting.sole
      manager.deactivate(setting_id: row.id, reason: "Historical")
      save(central, low: "9")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(row.reload).to have_attributes(status: "inactive", low_stock_level: 4)
      expect(state(central)).to eq("excluded")
      expect(card(central).text).to include("Historical")
    end

    it "an inactive warehouse is not included automatically and cannot be configured from the product page" do
      closed = business.warehouses.create!(name: "Closed WH", kind: "central", status: "inactive")
      get edit_inventory_product_path(product)
      expect(card(closed)).to be_nil
      save(closed, low: "3")
      expect(response.body).to include(ERB::Util.html_escape(I18n.t("product_availability.errors.not_included_by_default", warehouse: "Closed WH")))
      exclude(closed)
      expect(ProductWarehouseSetting.count).to eq(0)
    end

    it "a warehouse-scoped user does not see or reach a central warehouse outside their scope" do
      scoped = user_with_stock_permissions(business, :view_inventory, :manage_product_availability, name: "Scoped")
      scoped.assigned_warehouses << nasr
      sign_in scoped
      get availability_inventory_product_path(product)
      expect(card(central)).to be_nil
      expect(doc.at_css("[data-testid='availability-group-central']").text).to include(I18n.t("product_availability.section.groups.central.empty"))
      sign_in scoped
      save(central, low: "3", return_to: "product_availability")
      expect(response).to have_http_status(:not_found)
      expect(ProductWarehouseSetting.count).to eq(0)
    end
  end

  describe "editing settings in place" do
    before { sign_in editor }

    it "the first save of an Included branch creates its row (audited) and returns to the section" do
      save(nasr, low: "4", reorder: "12")

      expect(response).to redirect_to(edit_inventory_product_path(product, anchor: "availability"))
      expect(flash[:availability_notice]).to eq(I18n.t("product_availability.flash.updated", product: "Shampoo", warehouse: "Nasr City"))
      row = ProductWarehouseSetting.sole
      expect(row).to have_attributes(warehouse_id: nasr.id, status: "active", low_stock_level: 4, reorder_quantity: 12,
                                     receive_low_stock_notification: true, created_by_id: editor.id)
      expect(AuditLog.where(auditable: row, action: "availability_add", actor: editor).sole.metadata["source"]).to eq("product_page")
    end

    it "a later save updates the row, audited, without touching the product" do
      save(nasr, low: "4")
      save(nasr, low: "6", reorder: "2")
      row = ProductWarehouseSetting.sole
      expect(row).to have_attributes(low_stock_level: 6, reorder_quantity: 2)
      expect(AuditLog.where(auditable: row, action: "availability_update").count).to eq(1)
      expect(product.reload.name).to eq("Shampoo")
      expect(retired_product_stock_columns(product)["low_stock_level"]).to eq(77)
    end

    it "saving unchanged values writes nothing" do
      save(nasr, low: "4")
      before = AuditLog.count
      save(nasr, low: "4")
      expect(flash[:availability_notice]).to eq(I18n.t("product_availability.flash.unchanged"))
      expect(AuditLog.count).to eq(before)
    end

    it "a refused save re-renders the card with the reason by the fields and the typed values kept" do
      save(nasr, low: "-2", reorder: "15")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(doc.at_css("[data-testid='row-error-#{nasr.id}']").text).to eq("Nasr City: #{I18n.t('product_availability.errors.invalid_quantity')}")
      expect(card(nasr).at_css("#pws-#{nasr.id}-low")["value"]).to eq("-2")
      expect(card(nasr).at_css("#pws-#{nasr.id}-low")["aria-invalid"]).to eq("true")
      expect(card(nasr).at_css("#pws-#{nasr.id}-reorder")["value"]).to eq("15")
      expect(doc.at_css("[data-testid='availability-notice']")).to be_nil
      expect(ProductWarehouseSetting.count).to eq(0)
    end

    it "an audit failure writes nothing and keeps the typed values" do
      allow_any_instance_of(Inventory::ProductAvailabilityManager).to receive(:log_audit!).and_raise(AuditLoggable::AuditWriteFailed, "down")
      save(nasr, low: "8")
      expect(doc.at_css("[data-testid='row-error-#{nasr.id}']").text).to include(I18n.t("product_availability.errors.audit_failed"))
      expect(card(nasr).at_css("#pws-#{nasr.id}-low")["value"]).to eq("8")
      expect(ProductWarehouseSetting.count).to eq(0)
    end

    it "refuses low-stock settings for an untracked product" do
      product.update!(track_inventory: false)
      save(nasr, low: "3")
      expect(doc.at_css("[data-testid='availability-error']").text).to include(I18n.t("product_availability.errors.untracked_product"))
      expect(ProductWarehouseSetting.count).to eq(0)
    end

    it "an Excluded branch's settings cannot be saved until it is included again" do
      exclude(nasr)
      save(nasr, low: "3")
      expect(doc.at_css("[data-testid='row-error-#{nasr.id}']").text).to include(I18n.t("product_availability.errors.inactive"))
      expect(ProductWarehouseSetting.sole.low_stock_level).to eq(0)
    end
  end

  describe "excluding and including" do
    before { sign_in editor }

    it "loads the exclusion confirmation (effects + dependency summary) without writing anything" do
      stock!(nasr, 4)
      get availability_exclusion_inventory_product_path(product, warehouse_id: nasr.id, return_to: "product_edit"),
          headers: { "Turbo-Frame" => "exclusion_#{nasr.id}" }
      frame = doc.at_css("turbo-frame#exclusion_#{nasr.id}")
      expect(frame.text).to include(I18n.t("product_availability.exclusion.no_incoming"), I18n.t("product_availability.exclusion.outgoing_allowed"),
                                    I18n.t("product_availability.deactivation.receipts_exception"))
      expect(frame.at_css("[data-testid='dependency-summary']").text).to match(/On hand\s*4/)
      expect(ProductWarehouseSetting.count).to eq(0)
    end

    it "excludes an Included branch with no row: creates it Excluded with the reason, audited" do
      exclude(nasr, reason: "Not sold in Nasr City")
      expect(response).to redirect_to(edit_inventory_product_path(product, anchor: "availability"))
      expect(flash[:availability_notice]).to eq(I18n.t("product_availability.flash.excluded", product: "Shampoo", warehouse: "Nasr City"))
      row = ProductWarehouseSetting.sole
      expect(row).to have_attributes(status: "inactive", status_reason: "Not sold in Nasr City", status_changed_by_id: editor.id)
      audit = AuditLog.where(auditable: row, action: "availability_deactivate", actor: editor).sole
      expect(audit.metadata).to include("reason" => "Not sold in Nasr City", "included_by_default" => true)

      get edit_inventory_product_path(product)
      expect(state(nasr)).to eq("excluded")
      expect(card(nasr).at_css("[data-testid='exclude-#{nasr.id}']")["checked"]).to eq("checked")
    end

    it "excludes a branch that has settings, keeping them, and Include again restores them" do
      save(nasr, low: "5", reorder: "9")
      exclude(nasr)
      row = ProductWarehouseSetting.sole
      expect(row).to be_status_inactive

      post availability_inclusion_inventory_product_path(product), params: { warehouse_id: nasr.id, return_to: "product_edit" }
      expect(flash[:availability_notice]).to eq(I18n.t("product_availability.flash.included", product: "Shampoo", warehouse: "Nasr City"))
      expect(row.reload).to have_attributes(status: "active", low_stock_level: 5, reorder_quantity: 9)
      expect(AuditLog.where(auditable: row, action: "availability_reactivate").count).to eq(1)
    end

    it "is allowed with stock (decision N5): the stock stays on the books and the summary is audited" do
      stock!(nasr, 6)
      exclude(nasr)
      audit = AuditLog.find_by!(action: "availability_deactivate")
      expect(audit.metadata["dependencies"]).to include("on_hand" => "6.0")
      expect(Inventory::StockLevels.new(product).by_warehouse[nasr.id]).to eq(6)
    end

    it "refuses without a reason, keeping the panel open with the dependency summary" do
      exclude(nasr, reason: " ")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(doc.at_css("[data-testid='exclusion-error-#{nasr.id}']").text).to eq("Nasr City: #{I18n.t('product_availability.errors.reason_required')}")
      expect(card(nasr).at_css("[data-testid='dependency-summary']")).to be_present
      expect(doc.at_css("[data-testid='availability-notice']")).to be_nil
      expect(ProductWarehouseSetting.count).to eq(0)
    end

    it "an audit failure excludes nothing, keeps the typed reason and says why" do
      allow_any_instance_of(Inventory::ProductAvailabilityManager).to receive(:log_audit!).and_raise(AuditLoggable::AuditWriteFailed, "down")
      exclude(nasr, reason: "Moved to Shubra")
      expect(doc.at_css("[data-testid='exclusion-error-#{nasr.id}']").text).to eq("Nasr City: #{I18n.t('product_availability.errors.audit_failed')}")
      expect(card(nasr).at_css("#exclusion-reason-#{nasr.id}").text).to eq("Moved to Shubra")
      expect(ProductWarehouseSetting.count).to eq(0)
    end

    it "a duplicate exclusion is refused, never reported as success" do
      exclude(nasr, reason: "first")
      exclude(nasr, reason: "again")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(I18n.t("product_availability.errors.already_inactive"))
      expect(ProductWarehouseSetting.sole.status_reason).to eq("first")
      expect(AuditLog.where(action: "availability_deactivate").count).to eq(1)
    end
  end

  describe "the product form stays separate" do
    before { sign_in editor }

    it "saving general product details never touches availability" do
      save(nasr, low: "2")
      exclude(shubra)
      before = snapshot
      patch inventory_product_path(product), params: { product: { name: "Shampoo Pro", sku: "SH-1", notes: "n" } }
      expect(response).to redirect_to(inventory_product_path(product))
      expect(product.reload.attributes.slice("name", "notes")).to eq("name" => "Shampoo Pro", "notes" => "n")
      expect(snapshot).to eq(before)
    end

    it "a crafted product form carrying availability rows is refused" do
      before = snapshot
      patch inventory_product_path(product), params: { product: { name: "X", sku: "SH-1",
        product_warehouse_settings_attributes: { "0" => { warehouse_id: nasr.id, low_stock_level: 1 } } } }
      expect(response).to redirect_to(root_path)
      expect(snapshot).to eq(before)
    end
  end

  describe "authorization" do
    it "a user who edits products but cannot manage availability sees the cards read-only and is refused" do
      user = user_with_stock_permissions(business, :view_inventory, :manage_products, name: "Products only")
      sign_in user
      get edit_inventory_product_path(product)
      expect(card(nasr)).to be_present
      expect(card(nasr).css("form, input, button")).to be_empty

      save(nasr, low: "3")
      expect(doc.at_css("[data-testid='row-error-#{nasr.id}']").text).to eq("Nasr City: #{I18n.t('product_availability.errors.not_authorized')}")
      exclude(nasr)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(ProductWarehouseSetting.count).to eq(0)
    end

    it "a warehouse-scoped user sees only their branches and cannot reach another" do
      editor.assigned_warehouses << nasr
      sign_in editor
      get edit_inventory_product_path(product)
      expect(card(nasr)).to be_present
      expect(card(shubra)).to be_nil
      expect(response.body).not_to include("Shubra")

      sign_in editor
      save(shubra, low: "3")
      expect(response).to have_http_status(:not_found)
      sign_in editor
      exclude(shubra)
      expect(response).to have_http_status(:not_found)
      expect(ProductWarehouseSetting.count).to eq(0)
    end

    it "another business's warehouse or product is not found" do
      foreign_wh = other.warehouses.create!(name: "Foreign")
      foreign_product = other.products.create!(name: "F", sku: "F-1", initial_cost_price: 1, average_cost_price: 1)
      sign_in editor
      patch availability_settings_inventory_product_path(product), params: { warehouse_id: foreign_wh.id, product_warehouse_setting: { low_stock_level: 1 } }
      expect(response).to have_http_status(:not_found)
      sign_in editor
      post availability_exclusion_inventory_product_path(foreign_product), params: { warehouse_id: nasr.id, reason: "x" }
      expect(response).to have_http_status(:not_found)
      expect(ProductWarehouseSetting.count).to eq(0)
    end

    it "an availability manager who cannot edit products manages it on the standalone page" do
      user = user_with_stock_permissions(business, :view_inventory, :manage_product_availability, name: "Availability only")
      sign_in user
      get inventory_product_path(product)
      expect(doc.at_css("[data-testid='manage-availability']")["href"]).to eq(availability_inventory_product_path(product))
      get availability_inventory_product_path(product)
      expect(state(nasr)).to eq("included")

      save(nasr, low: "3", return_to: "product_availability")
      expect(response).to redirect_to(availability_inventory_product_path(product))
      expect(ProductWarehouseSetting.sole.low_stock_level).to eq(3)
    end

    it "a return target other than the named ones is ignored" do
      sign_in editor
      save(nasr, low: "3", return_to: "https://evil.example")
      expect(response).to redirect_to(availability_inventory_product_path(product))
    end
  end
end
