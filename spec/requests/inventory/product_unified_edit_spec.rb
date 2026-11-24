require "rails_helper"

# The product Edit page's ONE Save (Inventory::ProductEditor): product details
# (Measure and Amount included) and warehouse availability in one submission
# and one transaction — all saved, or nothing (audit entries included).
RSpec.describe "Product Edit — one Save for product and warehouses", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }

  def sales_warehouse(name)
    business.warehouses.create!(name: name, kind: "branch", branch: create(:branch, business: business, name: "#{name} branch"))
  end

  let!(:nasr)    { sales_warehouse("Nasr City") }
  let!(:shubra)  { sales_warehouse("Shubra") }
  let!(:product) { business.products.create!(name: "Gloves", sku: "GLV-1", initial_cost_price: 10, average_cost_price: 10) }
  let(:editor)   { user_with_stock_permissions(business, :view_inventory, :manage_products, :manage_product_availability, name: "Editor") }

  def doc = Nokogiri::HTML(response.body)

  # What the page submits: every section, as on the form.
  def save_all(product_attrs: {}, availability: {})
    patch inventory_product_path(product), params: {
      product: { name: product.name, sku: product.sku }.merge(product_attrs),
      availability: availability
    }
  end

  def snapshot
    product.reload
    [ product.attributes.except("updated_at"),
      ProductWarehouseSetting.order(:id).map(&:attributes), AuditLog.count ]
  end

  describe "the page" do
    before { sign_in editor }

    it "has exactly one Save button, for the whole page, and no section saves on its own" do
      get edit_inventory_product_path(product)
      # Every control that can submit a form on the page (inside a form, or
      # joined to one by the form attribute); the layout's own buttons aside.
      submits = doc.css("input[type='submit'], button[type='submit'], button:not([type])")
                   .select { |b| b["form"].present? || b.ancestors("form").any? }
      expect(submits.map { |b| b["data-testid"] }).to eq([ "product-save" ])
      expect(doc.at_css("[data-testid='product-save']")["value"]).to eq(I18n.t("inventory.products.save_all"))
      expect(doc.css("form").map { |f| f["id"] }.compact).to include("product-form")
      expect(doc.css("form").size).to eq(1)                                      # no warehouse form of its own
      expect(doc.at_css("[data-testid='packaging-section']")).to be_nil
      expect(doc.at_css("#pws-#{nasr.id}-low")["form"]).to eq("product-form")
      expect(doc.at_css("#pws-#{nasr.id}-low")["name"]).to eq("availability[#{nasr.id}][low_stock_level]")
      expect(doc.at_css("[data-testid='exclude-#{nasr.id}']")["form"]).to eq("product-form")
    end

    it "is translated in Arabic, right-to-left, with the one Save labelled 'حفظ جميع التعديلات'" do
      editor.update!(preferred_locale: "ar")
      get edit_inventory_product_path(product)
      expect(doc.at_css("html")["dir"]).to eq("rtl")
      expect(doc.at_css("[data-testid='product-save']")["value"]).to eq("حفظ جميع التعديلات")
      expect(response.body).not_to include("translation missing", "Translation missing")
    end
  end

  describe "one submission saves every section" do
    before { sign_in editor }

    it "product details (Measure and Amount included) and two warehouses' settings" do
      save_all(product_attrs: { name: "Hand cream", unit_of_measure: "ml", measure_amount: "355" },
               availability: { nasr.id.to_s => { low_stock_level: "3", reorder_quantity: "20", excluded: "0" },
                               shubra.id.to_s => { low_stock_level: "0", reorder_quantity: "0", excluded: "0" } })

      expect(response).to redirect_to(inventory_product_path(product))
      expect(flash[:notice]).to eq(I18n.t("inventory.products.all_saved"))
      product.reload
      expect([ product.name, product.unit_of_measure, product.measure_amount ]).to eq([ "Hand cream", "ml", 355 ])
      expect(ProductWarehouseSetting.sole).to have_attributes(warehouse_id: nasr.id, low_stock_level: 3, reorder_quantity: 20, status: "active")
      expect(AuditLog.where(action: "availability_add").count).to eq(1)        # Shubra unchanged (0 / 0): nothing written
      expect(InventoryMovement.count).to eq(0)
    end

    it "excludes a warehouse (reason required) and includes it again, each with the rest of the page" do
      save_all(availability: { nasr.id.to_s => { excluded: "1", reason: "Not sold here" } })
      expect(response).to redirect_to(inventory_product_path(product))
      row = ProductWarehouseSetting.sole
      expect([ row.warehouse_id, row.status, row.status_reason ]).to eq([ nasr.id, "inactive", "Not sold here" ])

      save_all(availability: { nasr.id.to_s => { excluded: "0" } })
      expect(row.reload.status).to eq("active")
    end
  end

  describe "any refusal saves nothing" do
    before { sign_in editor }

    let(:valid_availability) { { nasr.id.to_s => { low_stock_level: "5", reorder_quantity: "10", excluded: "0" } } }

    it "a warehouse refusal rolls back the product changes (Measure and Amount included), keeping every entry on the page" do
      before = snapshot
      save_all(product_attrs: { name: "Changed", unit_of_measure: "g", measure_amount: "500" },
               availability: { nasr.id.to_s => { low_stock_level: "-2", reorder_quantity: "15", excluded: "0" } })

      expect(response).to have_http_status(:unprocessable_entity)
      expect(snapshot).to eq(before)
      expect(doc.at_css("[data-testid='row-error-#{nasr.id}']").text).to eq("Nasr City: #{I18n.t('product_availability.errors.invalid_quantity')}")
      expect(doc.at_css("#pws-#{nasr.id}-low")["value"]).to eq("-2")
      expect(doc.at_css("#product_name")["value"]).to eq("Changed")
      expect(doc.at_css("select[name='product[unit_of_measure]'] option[selected]")["value"]).to eq("g")
      expect(doc.at_css("input[type='number'][name='product[measure_amount]']")["value"]).to eq("500")
      expect(doc.text).to include(I18n.t("inventory.products.nothing_saved"))
    end

    it "a product refusal saves none of the sections" do
      before = snapshot
      save_all(product_attrs: { name: "" }, availability: valid_availability)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(snapshot).to eq(before)
      expect(doc.at_css("#product_name")["class"]).to include("is-error")
    end

    it "an exclusion without a reason is refused with its panel and the rest rolled back" do
      before = snapshot
      save_all(product_attrs: { name: "Changed" }, availability: { nasr.id.to_s => { excluded: "1", reason: "" } })

      expect(response).to have_http_status(:unprocessable_entity)
      expect(snapshot).to eq(before)
      expect(doc.at_css("[data-testid='exclusion-error-#{nasr.id}']")).to be_present
      expect(doc.at_css("#exclusion-reason-#{nasr.id}")["form"]).to eq("product-form")
    end

    it "an audit failure in any section saves nothing" do
      before = snapshot
      fail_audit_writes!("availability_add")
      save_all(product_attrs: { name: "Changed" }, availability: valid_availability)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(snapshot).to eq(before)
    end
  end

  describe "authorization and inventory rules" do
    it "a warehouse the user may not manage is refused and nothing is saved" do
      editor.assigned_warehouses << nasr
      sign_in editor
      before = snapshot
      save_all(product_attrs: { name: "Changed" },
               availability: { nasr.id.to_s => { low_stock_level: "2", reorder_quantity: "0", excluded: "0" },
                               shubra.id.to_s => { low_stock_level: "9", reorder_quantity: "0", excluded: "0" } })
      expect(response).to have_http_status(:unprocessable_entity)
      expect(snapshot).to eq(before)
    end

    it "a user who edits products but cannot manage availability cannot change a warehouse through the one Save" do
      sign_in user_with_stock_permissions(business, :view_inventory, :manage_products, name: "Products only")
      before = snapshot
      save_all(product_attrs: { name: "Changed" }, availability: { nasr.id.to_s => { low_stock_level: "3", reorder_quantity: "0" } })
      expect(response).to have_http_status(:unprocessable_entity)
      expect(snapshot).to eq(before)
    end

    it "another business's warehouse is refused without naming it" do
      foreign = create(:business).warehouses.create!(name: "Foreign WH")
      sign_in editor
      before = snapshot
      save_all(product_attrs: { name: "Changed" }, availability: { foreign.id.to_s => { low_stock_level: "3", reorder_quantity: "0" } })
      expect(response).to have_http_status(:unprocessable_entity)
      expect(snapshot).to eq(before)
      expect(response.body).not_to include("Foreign WH")
    end

    it "a viewer cannot save the page at all" do
      sign_in user_with_stock_permissions(business, :view_inventory, name: "Viewer")
      before = snapshot
      save_all(product_attrs: { name: "Changed", unit_of_measure: "ml", measure_amount: "355" })
      expect(response).not_to have_http_status(:success)
      expect(snapshot).to eq(before)
    end

    it "after stock has moved, Measure and Amount stay editable and change directly; movements and stock are untouched" do
      InventoryMovement.create!(business: business, product: product, warehouse: nasr, direction: :in, quantity: 4, unit_cost: 10,
                                reason: :adjustment, occurred_on: Date.current)
      movements = InventoryMovement.order(:id).map(&:attributes)
      sign_in editor
      get edit_inventory_product_path(product)
      expect(doc.at_css("#product_unit_of_measure")["disabled"]).to be_nil
      expect(doc.at_css("[data-testid='unit-change'], [data-testid='base-unit-locked']")).to be_nil

      save_all(product_attrs: { unit_of_measure: "cm", measure_amount: "60" })
      expect(response).to redirect_to(inventory_product_path(product))
      expect([ product.reload.unit_of_measure, product.measure_amount ]).to eq([ "cm", 60 ])
      expect(InventoryMovement.order(:id).map(&:attributes)).to eq(movements)
      expect([ product.current_stock, product.average_cost_price ]).to eq([ 4, 10 ])
    end

    it "a crafted product form carrying availability rows is still refused" do
      sign_in editor
      patch inventory_product_path(product), params: { product: { name: "X", product_warehouse_settings_attributes: { "0" => { warehouse_id: nasr.id } } } }
      expect(response).not_to have_http_status(:success)
      expect(product.reload.name).to eq("Gloves")
    end
  end
end
