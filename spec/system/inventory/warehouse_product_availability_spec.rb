require "rails_helper"

# Phase 2 in a real browser: the warehouse Products tab (add with select-all,
# deactivate with a required reason, reactivate with confirmation) and the
# product page's Warehouse Availability card — desktop and phone widths, in
# English (LTR) and Arabic (RTL), with long Arabic names. Widths via Chrome
# device emulation (headless Chrome can't shrink a real window below ~500px).
RSpec.describe "Product availability per warehouse — browser", type: :system do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let!(:warehouse) { business.warehouses.create!(name: "مستودع الفرع الرئيسي بجوار مسجد النور الكبير - الترعة الجديدة", kind: "central") }
  let!(:shampoo) { business.products.create!(name: "شامبو العناية العميقة بالشعر التالف والمصبوغ - عبوة كبيرة", sku: "SH-1", initial_cost_price: 1, average_cost_price: 1) }
  let!(:mask)    { business.products.create!(name: "Mask", sku: "MK-1", initial_cost_price: 1, average_cost_price: 1) }
  let!(:towel)   { business.products.create!(name: "Towel", sku: "TW-1", initial_cost_price: 1, average_cost_price: 1) }
  let(:manager)  { Inventory::ProductAvailabilityManager.new(actor: owner) }

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

  def add!(product, **settings)
    manager.add_many(warehouse_id: warehouse.id, items: [ { product_id: product.id, **settings } ])
    ProductWarehouseSetting.find_by!(product: product, warehouse: warehouse)
  end

  { "en" => "ltr", "ar" => "rtl" }.each do |locale, dir|
    [ 390, 1024, 1440 ].each do |width|
      it "shows the Products tab without horizontal overflow (#{locale}, #{width}px)" do
        add!(shampoo, low_stock_level: 5)
        add!(mask).then { |row| manager.deactivate(setting_id: row.id, reason: "لم يعد مستخدمًا في هذا الفرع") }
        as(locale, width)
        visit inventory_warehouse_product_availabilities_path(warehouse)

        expect(page).to have_css("[data-availability-state]", count: 2)
        expect(js("document.documentElement.dir")).to eq(dir)
        expect(js("document.documentElement.scrollWidth")).to be <= width
        expect(find("[data-testid='warehouse-products-tab']")["aria-current"]).to eq("page")
        display = js("getComputedStyle(document.querySelector('tbody tr')).display")
        expect(display).to eq(width < 768 ? "block" : "table-row")
      end

      it "shows the product page's Warehouse Availability card without horizontal overflow (#{locale}, #{width}px)" do
        add!(shampoo, low_stock_level: 5, reorder_quantity: 10)
        as(locale, width)
        visit inventory_product_path(shampoo)

        expect(page).to have_css("[data-testid='warehouse-availability'] [data-availability-state='included']") # central: included by default
        expect(js("document.documentElement.scrollWidth")).to be <= width
      end
    end
  end

  it "adds products with select-all, keeps the count in the button, and reports the result" do
    add!(towel)
    as("en", 1440)
    visit new_inventory_warehouse_product_availability_path(warehouse)

    submit = find("[data-testid='add-selected']")
    expect(submit).to be_disabled
    find("input[data-availability-selection-target='master']").check
    expect(submit).not_to be_disabled
    expect(submit).to have_text("(2)")
    find("#items_#{mask.id}_selected").uncheck
    expect(submit).to have_text("(1)")
    fill_in "items_#{shampoo.id}_low_stock_level", with: "3"
    submit.click

    expect(page).to have_text("1 product added to")
    expect(ProductWarehouseSetting.find_by!(product: shampoo).low_stock_level).to eq(3)
    expect(ProductWarehouseSetting.where(product: mask)).to be_empty
  end

  it "deactivates only with a reason, then reactivates after confirmation" do
    row = add!(mask, low_stock_level: 2)
    as("en", 1440)
    visit deactivation_inventory_warehouse_product_availability_path(warehouse, row)

    expect(page).to have_text(I18n.t("product_availability.deactivation.blocks_incoming"))
    click_button "Confirm deactivation"
    expect(page).to have_current_path(deactivation_inventory_warehouse_product_availability_path(warehouse, row))
    expect(row.reload).to be_status_active # the browser refused the empty reason

    fill_in "Reason", with: "Not sold here any more"
    click_button "Confirm deactivation"
    expect(page).to have_text("Mask is now inactive in")
    expect(row.reload).to be_status_inactive

    accept_confirm { click_button "Reactivate" }
    expect(page).to have_text("Mask is active again in")
    expect(row.reload).to have_attributes(status: "active", low_stock_level: 2)
  end
end
