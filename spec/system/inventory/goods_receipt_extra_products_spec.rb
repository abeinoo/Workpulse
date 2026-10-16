require "rails_helper"

# Browser coverage (Arabic): creating a goods receipt from a Purchase Request
# shows the request's lines under "منتجات طلب الشراء", and "+ إضافة منتج"
# adds any catalog product under "منتجات إضافية" — saved without touching the
# request. Also checked at phone width.
#
# Set SCREENSHOT_DIR=/some/dir to also save screenshots.
RSpec.describe "Goods receipt from a Purchase Request — extra products (browser)", type: :system do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business, preferred_locale: "ar") }
  let(:supplier)  { business.suppliers.create!(name: "مورد مستحضرات") }
  let(:warehouse) { business.warehouses.create!(name: "المستودع الرئيسي") }

  def product(name, sku) = business.products.create!(name: name, sku: sku, average_cost_price: 10)

  let!(:shampoo) { product("شامبو", "SH-1") }
  let!(:mask)    { product("ماسك شعر", "MS-1") }
  let!(:cream)   { product("كريم شعر", "CR-1") }

  let!(:pr) do
    request = business.purchase_requests.build(supplier: supplier, source: "low_stock_alert", created_by: owner)
    request.items.build(product: shampoo, quantity: 10, unit_price: 20, source_warehouse: warehouse)
    request.items.build(product: mask,    quantity: 5,  unit_price: 30, source_warehouse: warehouse)
    request.save!
    request.update_columns(status: "pending_approval", submitted_by_id: owner.id)
    Inventory::PurchaseRequestApproval.new(purchase_request_id: request.id, actor: owner).approve!
    request.reload
  end

  def gr(key) = I18n.t("inventory.goods_receipts.#{key}", locale: :ar)

  def set_viewport(width, height = 1000)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: width, height: height, deviceScaleFactor: 1, mobile: width < 768)
  end

  def screenshot(name)
    dir = ENV["SCREENSHOT_DIR"]
    page.save_screenshot(File.join(dir, "#{name}.png")) if dir.present?
  end

  before { sign_in owner }

  [ 1280, 390 ].each do |width|
    it "adds an extra catalog product beside the request's lines and saves (#{width}px)" do
      set_viewport(width, width < 768 ? 2400 : 1400)
      visit new_inventory_goods_receipt_path(purchase_request_id: pr.id)

      expect(page).to have_css("tr.line-items-section", text: gr("request_items_title"))
      expect(page).to have_css("tr.line-items-section", text: gr("extra_items_title"))
      expect(page).to have_css("tr.line-items-row--request", count: 2)
      expect(page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")).to be <= 0

      choose gr("funding_source_kinds.supplier_credit")
      click_button "+ #{gr('add_product')}"
      new_row = all("tr[data-line-row]").last
      within(new_row) do
        expect(page).to have_text(gr("outside_request_badge"))
        find("select").find("option", text: /كريم شعر/).select_option
        find("input[name$='[quantity]']").fill_in(with: "3")
        find("input[name$='[unit_cost]']").fill_in(with: "15")
      end
      screenshot("gr_extra_products_#{width}")

      click_button gr("save_draft")
      expect(page).to have_text(gr("created"))

      receipt = business.goods_receipts.order(:id).last
      expect(receipt.purchase_request).to eq(pr)
      expect(receipt.items.map { |i| [ i.product.name, i.purchase_request_item_id.present? ] })
        .to contain_exactly([ "شامبو", true ], [ "ماسك شعر", true ], [ "كريم شعر", false ])
      expect(receipt.total_value).to eq(10 * 20 + 5 * 30 + 3 * 15)
      expect(pr.reload.items.count).to eq(2)
    end
  end
end
