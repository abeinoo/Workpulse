require "rails_helper"

# Browser behaviour of the "إنشاء طلب شراء" form: the floating product
# dropdown (never clipped by the line-items table, flips upward when there's
# no room below, LTR + RTL), the single initial line, manual line adding,
# client-side duplicate prevention, and the optional Low Stock picker.
RSpec.describe "Purchase Request creation form", type: :system do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let!(:supplier) { business.suppliers.create!(name: "Supplier 1") }
  let!(:main_wh)  { business.warehouses.create!(name: "Main WH") }
  let!(:other_wh) { business.warehouses.create!(name: "Other WH") }

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

  def choose_product(row, text)
    row.find(".searchable-select__input").click
    row.find(".searchable-select__option", text: text).click
  end

  { "en" => "ltr", "ar" => "rtl" }.each do |locale, dir|
    it "#{locale.upcase} #{dir.upcase}: the product dropdown floats above the table, searches, and closes on select" do
      owner.update!(preferred_locale: locale)
      sign_in owner
      visit new_inventory_purchase_request_path

      expect(page).to have_css("html[dir='#{dir}']")
      expect(rows.size).to eq(1)

      row   = rows.first
      input = row.find(".searchable-select__input")
      # Put the line near the top of the viewport so there is room below.
      page.execute_script(<<~JS, input.native)
        arguments[0].closest(".admin-page").style.paddingBottom = "1200px";
        arguments[0].scrollIntoView({ block: "center", behavior: "instant" });
      JS
      input.click
      menu  = row.find(".searchable-select__menu", visible: true)

      expect(menu_on_top?(menu)).to be(true)
      menu_box  = page.evaluate_script("arguments[0].getBoundingClientRect().toJSON()", menu.native)
      input_box = page.evaluate_script("arguments[0].getBoundingClientRect().toJSON()", input.native)
      expect(menu_box["left"]).to be_within(1).of(input_box["left"])
      expect(menu_box["width"]).to be_within(1).of(input_box["width"])
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
      expect(row).to have_css(".searchable-select__option", text: "Stocked Shampoo", visible: true)
      expect(row).not_to have_css(".searchable-select__option", text: "Low Conditioner", visible: true)

      row.find(".searchable-select__option", text: "Stocked Shampoo").click
      expect(row).not_to have_css(".searchable-select__menu", visible: true)
      expect(row.find("select[name*='[product_id]']", visible: :all).value).to eq(stocked_product.id.to_s)
      expect(input.value).to include("Stocked Shampoo")
      expect(rows.size).to eq(1)
    end
  end

  it "opens the dropdown upward when there is no room below" do
    sign_in owner
    visit new_inventory_purchase_request_path

    input = rows.first.find(".searchable-select__input")
    # Put the line at the very bottom of the viewport (padding above it so
    # its scroll container can actually scroll that far).
    page.execute_script(<<~JS, input.native)
      arguments[0].closest(".admin-page").style.paddingTop = "1200px";
      arguments[0].scrollIntoView({ block: "end", behavior: "instant" });
    JS
    expect(page.evaluate_script("window.innerHeight - arguments[0].getBoundingClientRect().bottom", input.native)).to be < 100
    input.click
    menu = rows.first.find(".searchable-select__menu", visible: true)

    menu_box  = page.evaluate_script("arguments[0].getBoundingClientRect().toJSON()", menu.native)
    input_box = page.evaluate_script("arguments[0].getBoundingClientRect().toJSON()", input.native)
    expect(menu_box["bottom"]).to be <= input_box["top"]
    expect(menu_box["top"]).to be >= 0
    expect(menu_on_top?(menu)).to be(true)
  end

  it "creates a request manually (no Low Stock involved), adding a second line by hand" do
    sign_in owner
    visit new_inventory_purchase_request_path

    select "Supplier 1", from: "purchase_request[supplier_id]"
    choose_product(rows.first, "Stocked Shampoo")
    rows.first.find("select[name*='[source_warehouse_id]']").select("Main WH")
    rows.first.find("input[name*='[quantity]']").fill_in(with: "10")
    rows.first.find("input[name*='[unit_price]']").fill_in(with: "20")

    click_button I18n.t("inventory.purchase_requests.form.add_item")
    expect(rows.size).to eq(2)
    choose_product(rows.last, "Low Conditioner")
    rows.last.find("select[name*='[source_warehouse_id]']").select("Other WH")
    rows.last.find("input[name*='[quantity]']").fill_in(with: "5")
    rows.last.find("input[name*='[unit_price]']").fill_in(with: "30")

    click_button I18n.t("inventory.purchase_requests.form.create_submit")

    expect(page).to have_content(I18n.t("inventory.purchase_requests.just_created_title"))
    request = PurchaseRequest.last
    expect(request.items.map { |i| [ i.product, i.source_warehouse, i.quantity.to_i ] })
      .to contain_exactly([ stocked_product, main_wh, 10 ], [ low_product, other_wh, 5 ])
  end

  it "blocks a duplicate product + warehouse line with an Arabic message, without touching the existing line" do
    owner.update!(preferred_locale: "ar")
    sign_in owner
    visit new_inventory_purchase_request_path

    choose_product(rows.first, "Stocked Shampoo")
    rows.first.find("select[name*='[source_warehouse_id]']").select("Main WH")
    rows.first.find("input[name*='[quantity]']").fill_in(with: "7")

    click_button I18n.t("inventory.purchase_requests.form.add_item", locale: "ar")
    rows.last.find("select[name*='[source_warehouse_id]']").select("Main WH")
    choose_product(rows.last, "Stocked Shampoo")

    expect(page).to have_content(I18n.t("inventory.purchase_requests.form.duplicate_line", locale: "ar"))
    expect(rows.last.find("select[name*='[product_id]']", visible: :all).value).to eq("")
    expect(rows.first.find("select[name*='[product_id]']", visible: :all).value).to eq(stocked_product.id.to_s)
    expect(rows.first.find("input[name*='[quantity]']").value).to eq("7")
  end

  it "adds products from the Low Stock picker into the existing empty line, alongside manual lines" do
    sign_in owner
    visit new_inventory_purchase_request_path

    click_button I18n.t("inventory.purchase_requests.form.add_from_low_stock")
    within("[data-purchase-request-form-target='lowStockModal']") do
      expect(page).to have_content("Low Conditioner")
      expect(page).not_to have_content("Stocked Shampoo")
      find("[data-low-stock-row][data-product-id='#{low_product.id}'] [data-low-stock-check]").check
      click_button I18n.t("inventory.purchase_requests.form.add_selected")
    end

    expect(rows.size).to eq(1) # reused the blank initial line — no extra empty line
    expect(rows.first.find("select[name*='[product_id]']", visible: :all).value).to eq(low_product.id.to_s)
    expect(rows.first.find(".searchable-select__input").value).to include("Low Conditioner")

    click_button I18n.t("inventory.purchase_requests.form.add_item")
    choose_product(rows.last, "Stocked Shampoo")
    rows.last.find("select[name*='[source_warehouse_id]']").select("Main WH")
    rows.last.find("input[name*='[quantity]']").fill_in(with: "3")
    rows.last.find("input[name*='[unit_price]']").fill_in(with: "20")
    rows.first.find("select[name*='[source_warehouse_id]']").select("Main WH") if rows.first.find("select[name*='[source_warehouse_id]']").value.blank?
    select "Supplier 1", from: "purchase_request[supplier_id]"

    click_button I18n.t("inventory.purchase_requests.form.create_submit")

    expect(page).to have_content(I18n.t("inventory.purchase_requests.just_created_title"))
    expect(PurchaseRequest.last.items.map(&:product)).to contain_exactly(low_product, stocked_product)
  end
end
