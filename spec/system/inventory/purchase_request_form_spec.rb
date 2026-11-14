require "rails_helper"

# Browser behaviour of the "إنشاء طلب شراء" form: the floating product
# dropdown (never clipped by the line-items table, flips upward when there's
# no room below, LTR + RTL), the single initial line, manual line adding,
# the one request-level warehouse, the per-line supplier (pre-filled from the
# product's default supplier, overridable), client-side duplicate prevention,
# and the optional Low Stock picker.
RSpec.describe "Purchase Request creation form", type: :system do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let!(:supplier) { business.suppliers.create!(name: "Supplier 1") }
  let!(:supplier_2) { business.suppliers.create!(name: "Supplier 2") }
  let!(:main_wh)  { business.warehouses.create!(name: "Main WH") }
  let!(:other_wh) { business.warehouses.create!(name: "Other WH") }
  let!(:responsible) { purchaser_with_custody(business, first_name: "Rami") }

  let!(:stocked_product) do
    business.products.create!(name: "Stocked Shampoo", sku: "STK-1", average_cost_price: 20,
                               low_stock_level: 5, reorder_level: 5, reorder_quantity: 10)
  end
  let!(:low_product) do
    business.products.create!(name: "Low Conditioner", sku: "LOW-1", average_cost_price: 30,
                               low_stock_level: 5, reorder_level: 5, reorder_quantity: 12)
  end

  before do
    { stocked_product => 50, low_product => 1 }.each do |product, qty|
      receipt = business.goods_receipts.build(warehouse: main_wh, received_on: Date.current)
      receipt.items.build(product: product, quantity: qty, unit_cost: product.average_cost_price)
      Inventory::GoodsReceiptPoster.new(receipt).call
    end
  end

  def rows = all("table.line-items-table tbody tr[data-line-row]")

  # The element actually painted at the menu's centre — proves the menu is on
  # top and not clipped/covered by the card or table around it.
  def menu_on_top?(menu)
    page.evaluate_script(<<~JS, menu.native)
      (function(m) { const r = m.getBoundingClientRect(); const hit = document.elementFromPoint(r.left + r.width / 2, r.top + Math.min(20, r.height / 2)); return m.contains(hit); })(arguments[0])
    JS
  end

  # The product picker (product-combobox) opens on focus and searches the
  # server; blur first so choosing another product on the same line opens it again.
  def choose_product(row, text)
    input = row.find("[data-product-combobox-target='input']")
    page.execute_script("arguments[0].blur()", input.native)
    # Centred first, so the opened menu is not under the page's bottom bar.
    page.execute_script("arguments[0].scrollIntoView({ block: 'center' })", input.native)
    input.click
    row.find(".pcombo__option", text: text).click
  end

  def supplier_select(row) = row.find("select[name*='[supplier_id]']")

  { "en" => "ltr", "ar" => "rtl" }.each do |locale, dir|
    it "#{locale.upcase} #{dir.upcase}: the product dropdown floats above the table, searches, and closes on select" do
      owner.update!(preferred_locale: locale)
      sign_in owner
      visit new_inventory_purchase_request_path

      expect(page).to have_css("html[dir='#{dir}']")
      expect(rows.size).to eq(1)

      row   = rows.first
      input = row.find("[data-product-combobox-target='input']")
      # Put the line near the top of the viewport so there is room below.
      page.execute_script(<<~JS, input.native)
        arguments[0].closest(".admin-page").style.paddingBottom = "1200px";
        arguments[0].scrollIntoView({ block: "center", behavior: "instant" });
      JS
      input.click
      menu  = row.find(".pcombo__listbox", visible: true)

      expect(menu_on_top?(menu)).to be(true)
      menu_box  = page.evaluate_script("arguments[0].getBoundingClientRect().toJSON()", menu.native)
      input_box = page.evaluate_script("arguments[0].getBoundingClientRect().toJSON()", input.native)
      expect(menu_box["left"]).to be_within(1).of(input_box["left"])
      expect(menu_box["width"]).to be >= input_box["width"] - 1 # never narrower than the field (min 280px)
      expect(menu_box["top"]).to be >= input_box["bottom"] # room below → opens down

      # Stays attached to the input while the page scrolls with it open.
      # Scroll events are dispatched on the next frame — measure after two.
      gap = page.evaluate_async_script(<<~JS, menu.native, input.native)
        const [menu, input, done] = arguments;
        window.scrollBy({ top: 60, behavior: "instant" });
        requestAnimationFrame(() => requestAnimationFrame(() =>
          done(menu.getBoundingClientRect().top - input.getBoundingClientRect().bottom)));
      JS
      expect(gap).to be_within(3).of(2)

      input.fill_in(with: "Stocked")
      expect(row).to have_css(".pcombo__option", text: "Stocked Shampoo", visible: true)
      expect(row).not_to have_css(".pcombo__option", text: "Low Conditioner", visible: true)

      row.find(".pcombo__option", text: "Stocked Shampoo").click
      expect(row).not_to have_css(".pcombo__listbox", visible: true)
      expect(row.find("select[name*='[product_id]']", visible: :all).value).to eq(stocked_product.id.to_s)
      expect(input.value).to include("Stocked Shampoo")
      expect(rows.size).to eq(1)
    end
  end

  it "opens the dropdown upward when there is no room below" do
    sign_in owner
    visit new_inventory_purchase_request_path

    input = rows.first.find("[data-product-combobox-target='input']")
    # Put the line at the very bottom of the viewport (padding above it so
    # its scroll container can actually scroll that far).
    page.execute_script(<<~JS, input.native)
      arguments[0].closest(".admin-page").style.paddingTop = "1200px";
      arguments[0].scrollIntoView({ block: "end", behavior: "instant" });
    JS
    expect(page.evaluate_script("window.innerHeight - arguments[0].getBoundingClientRect().bottom", input.native)).to be < 100
    input.click
    menu = rows.first.find(".pcombo__listbox", visible: true)

    menu_box  = page.evaluate_script("arguments[0].getBoundingClientRect().toJSON()", menu.native)
    input_box = page.evaluate_script("arguments[0].getBoundingClientRect().toJSON()", input.native)
    expect(menu_box["bottom"]).to be <= input_box["top"]
    expect(menu_box["top"]).to be >= 0
    expect(menu_on_top?(menu)).to be(true)
  end

  it "creates one request in one warehouse for lines of different suppliers, pre-filling each line's default supplier" do
    stocked_product.update!(default_supplier: supplier)
    sign_in owner
    visit new_inventory_purchase_request_path

    expect(page).to have_no_css("table.line-items-table select[name*='warehouse_id']")
    select "Other WH", from: "purchase_request[warehouse_id]"

    choose_product(rows.first, "Stocked Shampoo")
    expect(supplier_select(rows.first).value).to eq(supplier.id.to_s) # product default
    rows.first.find("input[name*='[quantity]']").fill_in(with: "10")
    rows.first.find("input[name*='[unit_price]']").fill_in(with: "20")

    click_button I18n.t("inventory.purchase_requests.form.add_item")
    expect(rows.size).to eq(2)
    choose_product(rows.last, "Low Conditioner")
    expect(supplier_select(rows.last).value).to eq("") # no default supplier: left unselected
    supplier_select(rows.last).select("Supplier 2")      # manual choice
    rows.last.find("input[name*='[quantity]']").fill_in(with: "5")
    rows.last.find("input[name*='[unit_price]']").fill_in(with: "30")

    find("select[name='purchase_request[responsible_employee_id]']").select(responsible.full_name)

    click_button I18n.t("inventory.purchase_requests.form.create_submit")

    expect(page).to have_content(I18n.t("inventory.purchase_requests.just_created_title"))
    expect(PurchaseRequest.count).to eq(1)
    request = PurchaseRequest.last
    expect(request.warehouse).to eq(other_wh)
    expect(request.items.map { |i| [ i.product, i.supplier, i.quantity.to_i ] })
      .to contain_exactly([ stocked_product, supplier, 10 ], [ low_product, supplier_2, 5 ])
    expect(low_product.reload.default_supplier).to be_nil
  end

  it "lets the user override the default supplier without changing the product, and re-defaults on a product change" do
    stocked_product.update!(default_supplier: supplier)
    low_product.update!(default_supplier: supplier_2)
    sign_in owner
    visit new_inventory_purchase_request_path

    choose_product(rows.first, "Stocked Shampoo")
    supplier_select(rows.first).select("Supplier 2")
    expect(supplier_select(rows.first).value).to eq(supplier_2.id.to_s)

    choose_product(rows.first, "Low Conditioner")
    expect(supplier_select(rows.first).value).to eq(supplier_2.id.to_s)
    choose_product(rows.first, "Stocked Shampoo")
    expect(supplier_select(rows.first).value).to eq(supplier.id.to_s)

    supplier_select(rows.first).select("Supplier 2")
    rows.first.find("input[name*='[quantity]']").fill_in(with: "1")
    rows.first.find("input[name*='[unit_price]']").fill_in(with: "20")
    select "Main WH", from: "purchase_request[warehouse_id]"
    find("select[name='purchase_request[responsible_employee_id]']").select(responsible.full_name)
    click_button I18n.t("inventory.purchase_requests.form.create_submit")

    expect(page).to have_content(I18n.t("inventory.purchase_requests.just_created_title"))
    expect(PurchaseRequest.last.items.sole.supplier).to eq(supplier_2)
    expect(stocked_product.reload.default_supplier).to eq(supplier)
  end

  it "blocks a duplicate product line with an Arabic message, without touching the existing line" do
    owner.update!(preferred_locale: "ar")
    sign_in owner
    visit new_inventory_purchase_request_path

    choose_product(rows.first, "Stocked Shampoo")
    rows.first.find("input[name*='[quantity]']").fill_in(with: "7")

    click_button I18n.t("inventory.purchase_requests.form.add_item", locale: "ar")
    supplier_select(rows.last).select("Supplier 2") # a different supplier doesn't make it a new line
    choose_product(rows.last, "Stocked Shampoo")

    expect(page).to have_content(I18n.t("inventory.purchase_requests.form.duplicate_line", locale: "ar"))
    expect(rows.last.find("select[name*='[product_id]']", visible: :all).value).to eq("")
    expect(rows.first.find("select[name*='[product_id]']", visible: :all).value).to eq(stocked_product.id.to_s)
    expect(rows.first.find("input[name*='[quantity]']").value).to eq("7")
  end

  it "keeps Low Stock rows of another warehouse out of the request" do
    stocked_product.product_warehouse_settings.create!(warehouse: other_wh, low_stock_level: 5, reorder_quantity: 3)
    sign_in owner
    visit new_inventory_purchase_request_path
    select "Main WH", from: "purchase_request[warehouse_id]"

    click_button I18n.t("inventory.purchase_requests.form.add_from_low_stock")
    within("[data-purchase-request-form-target='lowStockModal']") do
      # Not offered (no badge): one warehouse per request — a single note says why.
      expect(page).to have_no_css("[data-low-stock-row][data-product-id='#{stocked_product.id}']")
      expect(page).to have_text(I18n.t("inventory.purchase_requests.form.low_stock_hidden_rows", count: 1))
      # The total-stock alert fits any warehouse.
      expect(find("[data-low-stock-row][data-product-id='#{low_product.id}']")).to have_css("[data-low-stock-check]", visible: true)
    end
  end

  it "adds products from the Low Stock picker into the existing empty line, alongside manual lines" do
    sign_in owner
    visit new_inventory_purchase_request_path

    click_button I18n.t("inventory.purchase_requests.form.add_from_low_stock")
    within("[data-purchase-request-form-target='lowStockModal']") do
      expect(page).to have_content("Low Conditioner")
      expect(page).not_to have_content("Stocked Shampoo")
      find("[data-low-stock-row][data-product-id='#{low_product.id}'] [data-low-stock-check]").check
      click_button I18n.t("inventory.purchase_requests.form.add_selected_count", count: 1)
    end

    expect(rows.size).to eq(1) # reused the blank initial line — no extra empty line
    expect(rows.first.find("select[name*='[product_id]']", visible: :all).value).to eq(low_product.id.to_s)
    expect(rows.first.find("[data-product-combobox-target='input']").value).to include("Low Conditioner")

    click_button I18n.t("inventory.purchase_requests.form.add_item")
    choose_product(rows.last, "Stocked Shampoo")
    rows.last.find("input[name*='[quantity]']").fill_in(with: "3")
    rows.last.find("input[name*='[unit_price]']").fill_in(with: "20")
    select "Main WH", from: "purchase_request[warehouse_id]"

    find("select[name='purchase_request[responsible_employee_id]']").select(responsible.full_name)

    click_button I18n.t("inventory.purchase_requests.form.create_submit")

    expect(page).to have_content(I18n.t("inventory.purchase_requests.just_created_title"))
    expect(PurchaseRequest.last.items.map(&:product)).to contain_exactly(low_product, stocked_product)
    expect(PurchaseRequest.last.warehouse).to eq(main_wh)
  end
end
