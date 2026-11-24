require "rails_helper"

# The product Edit page's inventory section in a real browser: every active
# sales branch has a card automatically; values are edited in place (unsaved
# state shown) and saved with everything else by the page's ONE Save; a
# checkbox excludes a branch with a reason (applied on that Save), unticking an
# excluded one includes it again — at phone, tablet and desktop widths, in
# English (LTR) and Arabic (RTL), with many branches and long Arabic names.
RSpec.describe "Product Edit — availability per warehouse (browser)", type: :system do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:manager)  { Inventory::ProductAvailabilityManager.new(actor: owner) }

  def sales_warehouse(name)
    business.warehouses.create!(name: name, kind: "branch", branch: create(:branch, business: business, name: "#{name} — branch"))
  end

  let!(:long)    { sales_warehouse("مستودع فرع صالون جدو - الترعة البولاقية بجوار مسجد النور الكبير") }
  let!(:nasr)    { sales_warehouse("Nasr City") }
  let!(:shubra)  { sales_warehouse("Shubra") }
  let!(:product) { business.products.create!(name: "شامبو العناية العميقة بالشعر التالف - عبوة كبيرة", sku: "SH-1", initial_cost_price: 1, average_cost_price: 1) }
  let!(:central) { business.warehouses.create!(name: "المستودع المركزي الرئيسي - مدينة العبور الصناعية", kind: "central") }

  after { page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") }

  def emulate(width, height: 1000)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: width, height: height, deviceScaleFactor: 1, mobile: width < 768)
  end

  def js(script) = page.evaluate_script(script)

  def as(locale, width)
    owner.update!(preferred_locale: locale)
    sign_in owner
    emulate(width)
  end

  def card(warehouse) = find("[data-testid='availability-card-#{warehouse.id}']")

  { "en" => "ltr", "ar" => "rtl" }.each do |locale, dir|
    [ 390, 1024, 1440 ].each do |width|
      it "shows every sales branch as a card without horizontal overflow (#{locale}, #{width}px)" do
        6.times { |i| sales_warehouse("Branch #{i + 1} #{'— فرع طويل الاسم' * 2}") }
        manager.save_settings(product_id: product.id, warehouse_id: nasr.id, low_stock_level: 12_500.5, reorder_quantity: 1_000_000)
        manager.exclude(product_id: product.id, warehouse_id: shubra.id, reason: "لم يعد هذا المنتج مستخدمًا في هذا الفرع")
        as(locale, width)
        visit edit_inventory_product_path(product)

        expect(page).to have_css("[data-testid='availability-group-branches'] [data-testid^='availability-card']", count: 9)
        expect(page).to have_css("[data-testid='availability-group-central'] [data-testid='availability-card-#{central.id}'] [data-testid='exclude-#{central.id}']")
        expect(page).not_to have_text("Add to warehouses")
        expect(js("document.documentElement.dir")).to eq(dir)
        expect(js("document.documentElement.scrollWidth")).to be <= width
        expect(card(shubra)["data-availability-card-state"]).to eq("excluded")
        # Every card carries its exclusion checkbox; none has a Save of its own.
        within(card(nasr)) { expect(page).to have_css("[data-testid='exclude-#{nasr.id}']") }
        expect(page).to have_no_css("[data-testid^='save-']")
        expect(page).to have_css("[data-testid='product-save']", count: 1)
      end
    end
  end

  def save_all = find("[data-testid='product-save']").click

  it "edits values in place, shows them unsaved, and saves them with the product details by the one Save" do
    as("en", 1440)
    visit edit_inventory_product_path(product)
    expect(page).to have_no_css("[data-testid='unsaved-changes']", visible: true)
    fill_in "product[name]", with: "Deep care shampoo"
    fill_in "pws-#{nasr.id}-low", with: "4"
    expect(find("[data-testid='unsaved-#{nasr.id}']")).to be_visible
    expect(page).to have_css("[data-testid='unsaved-changes']", visible: true, text: /unsaved changes/i)
    save_all

    expect(page).to have_text(I18n.t("inventory.products.all_saved"))
    expect(ProductWarehouseSetting.find_by!(warehouse: nasr).low_stock_level).to eq(4)
    expect(product.reload.name).to eq("Deep care shampoo")
  end

  it "a refused save keeps every typed value, says why by the card, and saves nothing" do
    as("en", 1440)
    visit edit_inventory_product_path(product)
    fill_in "product[name]", with: "Typed name"
    fill_in "pws-#{shubra.id}-low", with: "9"
    allow_any_instance_of(Inventory::ProductAvailabilityManager).to receive(:log_audit!).and_raise(AuditLoggable::AuditWriteFailed, "down")
    fill_in "pws-#{nasr.id}-low", with: "7"
    save_all

    expect(page).to have_text(I18n.t("inventory.products.nothing_saved"))
    expect(page).to have_css("[data-testid^='row-error-']", text: I18n.t("product_availability.errors.audit_failed"))
    expect(find_field("pws-#{nasr.id}-low").value).to eq("7")
    expect(find_field("pws-#{shubra.id}-low").value).to eq("9")
    expect(find_field("product[name]").value).to eq("Typed name")
    expect(ProductWarehouseSetting.count).to eq(0)
    expect(product.reload.name).not_to eq("Typed name")
  end

  it "excludes a branch with its checkbox and a reason on Save, then includes it again" do
    as("en", 1440)
    visit edit_inventory_product_path(product)

    within(card(nasr)) do
      check "Exclude this product from this warehouse"
      expect(page).to have_css("[data-testid='dependency-summary']")
      expect(page).to have_text(I18n.t("product_availability.exclusion.no_incoming"))
      expect(page).to have_no_button("Exclude from this warehouse")         # applied by the one Save
      uncheck "Exclude this product from this warehouse"                    # changing your mind writes nothing
      expect(page).not_to have_css("[data-testid='dependency-summary']", visible: true)
      check "Exclude this product from this warehouse"
    end
    save_all                                                                 # no reason: refused, nothing saved
    expect(page).to have_css("[data-testid='exclusion-error-#{nasr.id}']")
    expect(ProductWarehouseSetting.count).to eq(0)
    within(card(nasr)) do
      expect(find("[data-testid='exclude-#{nasr.id}']")).to be_checked
      fill_in "Reason for excluding", with: "Not sold in Nasr City"
    end
    save_all
    expect(page).to have_text(I18n.t("inventory.products.all_saved"))
    row = ProductWarehouseSetting.sole
    expect(row).to have_attributes(status: "inactive", status_reason: "Not sold in Nasr City")

    visit edit_inventory_product_path(product)
    expect(card(nasr)["data-availability-card-state"]).to eq("excluded")
    within(card(nasr)) do
      uncheck "Exclude this product from this warehouse"
      expect(page).to have_css("[data-testid='include-on-save-#{nasr.id}']", visible: true)
    end
    save_all
    expect(page).to have_text(I18n.t("inventory.products.all_saved"))
    expect(row.reload).to be_status_active
  end

  it "the central warehouse works exactly like a branch: included by default, edited in place, excluded with its checkbox" do
    as("en", 1440)
    visit edit_inventory_product_path(product)

    within("[data-testid='availability-group-central']") do
      expect(page).not_to have_button("Add to this central warehouse")
      expect(find("[data-testid='availability-card-#{central.id}']")["data-availability-card-state"]).to eq("included")
      fill_in "pws-#{central.id}-low", with: "40"
    end
    save_all
    expect(page).to have_text(I18n.t("inventory.products.all_saved"))
    row = ProductWarehouseSetting.sole
    expect(row).to have_attributes(warehouse_id: central.id, low_stock_level: 40)

    visit edit_inventory_product_path(product)
    within("[data-testid='availability-card-#{central.id}']") do
      check "Exclude this product from this warehouse"
      expect(page).to have_css("[data-testid='dependency-summary']")
      fill_in "Reason for excluding", with: "Not stocked centrally"
    end
    save_all
    expect(page).to have_text(I18n.t("inventory.products.all_saved"))
    expect(row.reload).to be_status_inactive
  end

  { "en" => [ "Exclude this product from this warehouse", "Reason for excluding" ],
    "ar" => [ "استبعاد المنتج من هذا المستودع", "سبب الاستبعاد" ] }.each do |locale, (exclude_label, reason_label)|
    it "a refusal elsewhere keeps the open exclusion panel, its typed reason and other cards' typing; nothing is saved (#{locale})" do
      as(locale, 1440)
      visit edit_inventory_product_path(product)

      within(card(nasr)) do
        check exclude_label
        expect(page).to have_css("[data-testid='dependency-summary']")
        fill_in reason_label, with: "Moved to Shubra"
      end
      fill_in "pws-#{long.id}-low", with: "9"
      fill_in "product[name]", with: ""                                     # the product section is refused
      save_all

      expect(page).to have_text(I18n.t("inventory.products.nothing_saved", locale: locale))
      within(card(nasr)) do
        expect(find("[data-testid='exclude-#{nasr.id}']")).to be_checked
        expect(page).to have_css("[data-testid='dependency-summary']")
        expect(page).to have_field(reason_label, with: "Moved to Shubra")   # waits for the panel's frame
      end
      expect(find_field("pws-#{long.id}-low").value).to eq("9")
      expect(ProductWarehouseSetting.count).to eq(0)
      expect(js("document.documentElement.dir")).to eq(locale == "ar" ? "rtl" : "ltr")
    end
  end

  { "en" => "ltr", "ar" => "rtl" }.each do |locale, dir|
    it "stale product-level values: no product-level field; the central card shows its own defaults like a branch (#{locale})" do
      write_retired_product_stock_columns!(product, low_stock_level: 6, reorder_quantity: 12, reorder_level: 6)
      as(locale, 390)
      visit edit_inventory_product_path(product)

      within(card(central)) do
        expect(page).to have_field("pws-#{central.id}-low", with: "0")
        expect(page).to have_field("pws-#{central.id}-reorder", with: "0")
        expect(page).to have_css("[data-testid='exclude-#{central.id}']")
        expect(page).to have_no_css("[data-testid='save-#{central.id}']")
      end
      expect(page).to have_no_css("[data-testid^='pending-transfer'], [data-testid^='legacy-low-stock'], [data-testid^='legacy-reorder']")
      expect(js("document.documentElement.dir")).to eq(dir)
      expect(js("document.documentElement.scrollWidth")).to be <= 390
      expect(ProductWarehouseSetting.count).to eq(0)
    end
  end

  { "en" => [ "ltr", "ml" ], "ar" => [ "rtl", "مل" ] }.each do |locale, (dir, ml)|
    it "one Save: product details (Measure and Amount) and a warehouse setting together; one success message (#{locale})" do
      as(locale, 1440)
      visit edit_inventory_product_path(product)
      expect(page).to have_css("[data-testid='product-save']", count: 1)
      expect(page).to have_no_css("[data-testid='packaging-section'], [data-testid^='save-'], [data-testid^='confirm-exclusion']")

      fill_in "product[name]", with: "Hand cream"
      find("#product_unit_of_measure").select(I18n.t("inventory.measures.ml.name", locale: locale))
      expect(page).to have_css("[data-testid='product-measure-amount-suffix']", exact_text: ml)
      find("[data-testid='product-measure-amount']").fill_in(with: "355")
      fill_in "pws-#{nasr.id}-low", with: "3"
      expect(page).to have_css("[data-testid='unsaved-changes']", visible: true)
      expect(js("document.documentElement.dir")).to eq(dir)
      expect(js("document.documentElement.scrollWidth")).to be <= 1440
      save_all

      expect(page).to have_text(I18n.t("inventory.products.all_saved", locale: locale), count: 1)
      product.reload
      expect([ product.name, product.unit_of_measure, product.measure_amount ]).to eq([ "Hand cream", "ml", 355 ])
      expect(ProductWarehouseSetting.find_by!(warehouse: nasr).low_stock_level).to eq(3)
    end
  end

  it "the card controls are reachable by keyboard" do
    as("en", 1440)
    visit edit_inventory_product_path(product)
    find("[data-testid='exclude-#{nasr.id}']").send_keys(:tab)
    expect(js("document.activeElement.id")).to eq("pws-#{nasr.id}-low")
    page.send_keys("1", :tab)
    expect(js("document.activeElement.id")).to eq("pws-#{nasr.id}-reorder")
    find("[data-testid='exclude-#{nasr.id}']").send_keys(:space)
    expect(page).to have_css("#exclusion-panel-#{nasr.id} [data-testid='dependency-summary']")
  end

  # No Manage Availability action on the Show page (owner decision, Nov 2026):
  # the Edit page's section is reached through Edit.
  it "the Show page offers no Manage Availability action; Edit still holds the section" do
    manager.save_settings(product_id: product.id, warehouse_id: nasr.id, low_stock_level: 2, reorder_quantity: 0)
    as("en", 1440)
    visit inventory_product_path(product)
    expect(page).to have_no_link("Manage availability")
    find(".pshow-header__actions").click_link(I18n.t("common.edit"))
    expect(page).to have_css("#availability [data-testid='availability-card-#{nasr.id}']")
  end
end
