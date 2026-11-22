require "rails_helper"

# Browser coverage: receiving a Purchase Request whose lines name several
# suppliers. Choosing a supplier shows only that supplier's lines (with
# ordered / received / remaining), switching supplier swaps them, the total
# follows the quantities — in a wide, sectioned form (Arabic RTL and English
# LTR) that does not overflow on a phone.
RSpec.describe "Goods Receipt — supplier receiving (browser)", type: :system do
  let(:business)  { create(:business) }
  let(:admin)     { create(:user, :super_admin, business: business) }
  let!(:acme)     { business.suppliers.create!(name: "Acme") }
  let!(:beta)     { business.suppliers.create!(name: "Beta") }
  let!(:warehouse) { business.warehouses.create!(name: "Main") }
  let!(:soap)     { business.products.create!(name: "Soap", sku: "SO-1", average_cost_price: 5) }
  let!(:towel)    { business.products.create!(name: "Towel", sku: "TW-1", average_cost_price: 8) }
  let!(:comb)     { business.products.create!(name: "Comb", sku: "CB-1", average_cost_price: 2) }

  # Soap from Acme, Towel from Beta, Comb with no supplier.
  let!(:pr) do
    request = business.purchase_requests.build(warehouse: warehouse, created_by: admin)
    request.items.build(product: soap, quantity: 10, unit_price: 5, supplier: acme)
    request.items.build(product: towel, quantity: 4, unit_price: 8, supplier: beta)
    request.items.build(product: comb, quantity: 6, unit_price: 2)
    request.save!
    request.update_columns(status: "pending_approval", submitted_by_id: admin.id)
    Inventory::PurchaseRequestApproval.new(purchase_request_id: request.id, actor: admin).approve!
    request.reload
  end

  def gr(key, locale) = I18n.t("inventory.goods_receipts.#{key}", locale: locale)

  def set_viewport(width, height = 1400)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: width, height: height, deviceScaleFactor: 1, mobile: width < 768)
  end

  def line_products = all("[data-testid='gr-request-line']").map { |row| row.find("select[name$='[product_id]']", visible: :all).find("option[selected]", visible: :all).text }

  def expect_no_overflow
    expect(page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")).to be <= 0
  end

  %w[ar en].each do |locale|
    it "choosing a supplier lists only its lines; switching swaps them; the total follows (#{locale})" do
      admin.update!(preferred_locale: locale)
      set_viewport(1280)
      sign_in admin
      visit new_inventory_goods_receipt_path(purchase_request_id: pr.id)

      expect(page).to have_css("html[dir='#{locale == 'ar' ? 'rtl' : 'ltr'}']")
      expect(page).to have_content(gr("choose_supplier_title", locale))
      click_link "Acme"

      expect(page).to have_css("[data-testid='gr-selected-supplier-name']", text: "Acme")
      expect(line_products).to eq([ "Soap (SO-1)" ])
      within("[data-testid='gr-request-line']") do
        expect(find("[data-testid='gr-line-remaining']").text).to eq("10 #{I18n.t('inventory.measures.pieces.short', locale: locale)}")
        find("input[name$='[entered_quantity]']").fill_in(with: "4")
        find("input[name$='[entered_unit_cost]']").fill_in(with: "5")
      end
      expect(find("[data-testid='gr-grand-total']").text).to include("20.00")

      # The form uses the content area's width — no longer the old 640px column.
      widths = page.evaluate_script(<<~JS)
        (function() {
          const page = document.querySelector(".form-page--receipt");
          const style = getComputedStyle(page.parentElement);
          const available = page.parentElement.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
          return { form: document.querySelector(".gr-form").getBoundingClientRect().width, available: available };
        })()
      JS
      expect(widths["form"]).to be > 700
      expect(widths["form"].to_f / widths["available"]).to be > 0.85
      expect(page).to have_css("[data-testid='gr-form-actions'] input[type='submit']")
      expect_no_overflow

      find("[data-testid='gr-switch-supplier']", text: "Beta").click
      expect(page).to have_css("[data-testid='gr-selected-supplier-name']", text: "Beta")
      expect(line_products).to eq([ "Towel (TW-1)" ])

      find("[data-testid='gr-switch-supplier']", text: gr("no_supplier_lines", locale)).click
      expect(page).to have_css("[data-testid='gr-selected-supplier-name']", text: gr("no_supplier_lines", locale))
      expect(line_products).to eq([ "Comb (CB-1)" ])
    end
  end

  it "saves a partial receipt for one supplier, leaving the other supplier's lines untouched" do
    sign_in admin
    visit new_inventory_goods_receipt_path(purchase_request_id: pr.id, supplier_id: acme.id)
    choose gr("funding_source_kinds.supplier_credit", :en)
    within("[data-testid='gr-request-line']") { find("input[name$='[entered_quantity]']").fill_in(with: "3") }
    click_button gr("save_draft", :en)

    expect(page).to have_current_path(%r{/inventory/goods_receipts/\d+\z})
    receipt = GoodsReceipt.last
    expect(receipt).to have_attributes(supplier: acme, purchase_request: pr)
    expect(receipt.items.map { |i| [ i.product, i.quantity ] }).to eq([ [ soap, 3 ] ])
  end

  it "on a phone the form stacks without horizontal overflow, the actions stay reachable" do
    admin.update!(preferred_locale: "ar")
    set_viewport(390, 844)
    sign_in admin
    visit new_inventory_goods_receipt_path(purchase_request_id: pr.id, supplier_id: acme.id)

    expect(page).to have_css("[data-testid='gr-request-line']")
    expect_no_overflow
    qty = find("[data-testid='gr-request-line'] input[name$='[entered_quantity]']")
    expect(qty.native.rect.width).to be >= 120 # never an unusably small input
    expect(page).to have_css("[data-testid='gr-form-actions']", visible: true)
  end
end
