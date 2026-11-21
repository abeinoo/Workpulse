require "rails_helper"

# The product Edit page's inventory section in a real browser: every active
# sales branch has a card automatically, values are edited and saved in
# place (unsaved state shown, other cards' typing kept), a checkbox excludes a
# branch after a reason, "Include again" undoes it — at phone, tablet and
# desktop widths, in English (LTR) and Arabic (RTL), with many branches and
# long Arabic names.
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
        # Every card carries its own exclusion checkbox and Save.
        within(card(nasr)) { expect(page).to have_css("[data-testid='exclude-#{nasr.id}'], [data-testid='save-#{nasr.id}']", count: 2) }
      end
    end
  end

  it "edits values in place: Save enables on change, shows unsaved state, saves without touching the product form" do
    as("en", 1440)
    visit edit_inventory_product_path(product)
    fill_in "product[name]", with: "Unsaved product name"

    save = find("[data-testid='save-#{nasr.id}']")
    expect(save).to be_disabled
    fill_in "pws-#{nasr.id}-low", with: "4"
    expect(save).not_to be_disabled
    expect(find("[data-testid='unsaved-#{nasr.id}']")).to be_visible
    save.click

    expect(page).to have_css("[data-testid='availability-notice']", text: "Settings saved")
    expect(ProductWarehouseSetting.find_by!(warehouse: nasr).low_stock_level).to eq(4)
    expect(find_field("product[name]").value).to eq("Unsaved product name") # only the section refreshed
    expect(product.reload.name).not_to eq("Unsaved product name")
  end

  it "a refused save keeps the typed values with the reason by the fields; other cards' typing survives" do
    as("en", 1440)
    visit edit_inventory_product_path(product)
    fill_in "pws-#{shubra.id}-low", with: "9" # typed, not saved
    allow_any_instance_of(Inventory::ProductAvailabilityManager).to receive(:log_audit!).and_raise(AuditLoggable::AuditWriteFailed, "down")
    fill_in "pws-#{nasr.id}-low", with: "7"
    find("[data-testid='save-#{nasr.id}']").click

    expect(page).to have_css("[data-testid='row-error-#{nasr.id}']", text: I18n.t("product_availability.errors.audit_failed"))
    expect(find_field("pws-#{nasr.id}-low").value).to eq("7")
    expect(find_field("pws-#{shubra.id}-low").value).to eq("9")
    expect(page).not_to have_css("[data-testid='availability-notice']")
    expect(ProductWarehouseSetting.count).to eq(0)
  end

  it "excludes a branch with its checkbox after a reason, then includes it again" do
    as("en", 1440)
    visit edit_inventory_product_path(product)

    within(card(nasr)) do
      check "Exclude this product from this warehouse"
      expect(page).to have_css("[data-testid='dependency-summary']")
      expect(page).to have_text(I18n.t("product_availability.exclusion.no_incoming"))
      uncheck "Exclude this product from this warehouse" # changing your mind writes nothing
      expect(page).not_to have_css("[data-testid='dependency-summary']", visible: true)
      check "Exclude this product from this warehouse"
      click_button "Exclude from this warehouse"
      expect(ProductWarehouseSetting.count).to eq(0) # the browser requires the reason
      fill_in "Reason for excluding", with: "Not sold in Nasr City"
      click_button "Exclude from this warehouse"
    end
    expect(page).to have_css("[data-testid='availability-notice']", text: "is now excluded")
    expect(card(nasr)["data-availability-card-state"]).to eq("excluded")
    row = ProductWarehouseSetting.sole
    expect(row).to have_attributes(status: "inactive", status_reason: "Not sold in Nasr City")

    within(card(nasr)) do
      uncheck "Exclude this product from this warehouse"
      click_button "Include again"
    end
    expect(page).to have_css("[data-testid='availability-notice']", text: "included in")
    expect(row.reload).to be_status_active
  end

  it "the central warehouse works exactly like a branch: included by default, edited in place, excluded with its checkbox" do
    as("en", 1440)
    visit edit_inventory_product_path(product)

    within("[data-testid='availability-group-central']") do
      expect(page).not_to have_button("Add to this central warehouse")
      expect(find("[data-testid='availability-card-#{central.id}']")["data-availability-card-state"]).to eq("included")
      fill_in "pws-#{central.id}-low", with: "40"
      find("[data-testid='save-#{central.id}']").click
    end
    expect(page).to have_css("[data-testid='availability-notice']", text: "Settings saved")
    row = ProductWarehouseSetting.sole
    expect(row).to have_attributes(warehouse_id: central.id, low_stock_level: 40)

    within("[data-testid='availability-card-#{central.id}']") do
      check "Exclude this product from this warehouse"
      expect(page).to have_css("[data-testid='dependency-summary']")
      fill_in "Reason for excluding", with: "Not stocked centrally"
      click_button "Exclude from this warehouse"
    end
    expect(page).to have_css("[data-testid='availability-notice']", text: "is now excluded")
    expect(row.reload).to be_status_inactive
    expect(find("[data-testid='availability-card-#{central.id}']")["data-availability-card-state"]).to eq("excluded")
  end

  { "en" => [ "Exclude this product from this warehouse", "Reason for excluding" ],
    "ar" => [ "استبعاد المنتج من هذا المستودع", "سبب الاستبعاد" ] }.each do |locale, (exclude_label, reason_label)|
    it "keeps an open exclusion panel and its typed reason when another card is saved, without submitting it (#{locale})" do
      as(locale, 1440)
      visit edit_inventory_product_path(product)

      within(card(nasr)) do
        check exclude_label
        expect(page).to have_css("[data-testid='dependency-summary']")
        fill_in reason_label, with: "Moved to Shubra — typed, not sent"
      end
      fill_in "pws-#{long.id}-low", with: "9" # another card: typed, not saved
      fill_in "pws-#{shubra.id}-low", with: "6"
      find("[data-testid='save-#{shubra.id}']").click

      expect(page).to have_css("[data-testid='availability-notice']")
      expect(ProductWarehouseSetting.find_by!(warehouse: shubra).low_stock_level).to eq(6)
      within(card(nasr)) do
        expect(find("[data-testid='exclude-#{nasr.id}']")).to be_checked
        expect(page).to have_css("[data-testid='dependency-summary']")
        expect(page).to have_field(reason_label, with: "Moved to Shubra — typed, not sent") # waits for the panel's frame
      end
      expect(find_field("pws-#{long.id}-low").value).to eq("9")
      expect(ProductWarehouseSetting.where(warehouse: nasr)).to be_empty # the exclusion was never submitted
      expect(ProductWarehouseSetting.where(warehouse: long)).to be_empty
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
        expect(page).to have_css("[data-testid='save-#{central.id}'], [data-testid='exclude-#{central.id}']", count: 2)
      end
      expect(page).to have_no_css("[data-testid^='pending-transfer'], [data-testid^='legacy-low-stock'], [data-testid^='legacy-reorder']")
      expect(js("document.documentElement.dir")).to eq(dir)
      expect(js("document.documentElement.scrollWidth")).to be <= 390
      expect(ProductWarehouseSetting.count).to eq(0)
    end
  end

  it "the card controls are reachable by keyboard" do
    as("en", 1440)
    visit edit_inventory_product_path(product)
    find("[data-testid='exclude-#{nasr.id}']").send_keys(:tab)
    expect(js("document.activeElement.id")).to eq("pws-#{nasr.id}-low")
    page.send_keys("1", :tab, :tab)
    expect(js("document.activeElement.dataset.testid")).to eq("save-#{nasr.id}")
    find("[data-testid='exclude-#{nasr.id}']").send_keys(:space)
    expect(page).to have_css("#exclusion-panel-#{nasr.id} [data-testid='dependency-summary']")
  end

  it "the Show page summary links to the Edit page's section" do
    manager.save_settings(product_id: product.id, warehouse_id: nasr.id, low_stock_level: 2, reorder_quantity: 0)
    as("en", 1440)
    visit inventory_product_path(product)
    click_link "Manage availability"
    expect(page).to have_css("#availability [data-testid='availability-card-#{nasr.id}']")
  end
end
