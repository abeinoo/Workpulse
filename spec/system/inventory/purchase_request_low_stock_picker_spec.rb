require "rails_helper"

# The "اختيار منتجات من المخزون المنخفض" picker on the new Purchase Request form:
# select all / deselect all / indeterminate, the live count and Add label,
# quantities kept and validated (> 0, modal stays open), rows that can't be
# added (already on the request, another warehouse) not offered, the request's
# one warehouse, zero-stock highlighting, and RTL. Business rules (one line per
# product, one warehouse per request) are unchanged — the server rejects either.
RSpec.describe "Purchase Request Low Stock picker", type: :system do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }
  let!(:main_wh)  { business.warehouses.create!(name: "Main WH") }
  let!(:other_wh) { business.warehouses.create!(name: "Other WH") }

  # Low (threshold 5) in `warehouse`, with that warehouse's own reorder quantity.
  def low_product(name, sku, reorder_quantity: 10, warehouse: main_wh)
    business.products.create!(name: name, sku: sku, average_cost_price: 10).tap do |p|
      p.product_warehouse_settings.create!(warehouse: warehouse, low_stock_level: 5, reorder_quantity: reorder_quantity)
    end
  end

  # Main WH alerts: Alpha 0 on hand (out of stock), Beta 1, Gamma 2.
  let!(:alpha) { low_product("Alpha Dye", "AL-1") }
  let!(:beta)  { low_product("Beta Oil", "BE-1", reorder_quantity: 12) }
  let!(:gamma) { low_product("Gamma Gel", "GA-1") }

  before do
    { beta => 1, gamma => 2 }.each do |product, qty|
      receipt = business.goods_receipts.build(warehouse: main_wh, received_on: Date.current)
      receipt.items.build(product: product, quantity: qty, unit_cost: 10)
      Inventory::GoodsReceiptPoster.new(receipt).call
    end
  end

  def form(key, **) = I18n.t("inventory.purchase_requests.form.#{key}", **)
  def modal = find("[data-purchase-request-form-target='lowStockModal']")
  def row_for(product) = modal.find("[data-low-stock-row][data-product-id='#{product.id}']")
  def check_for(product) = row_for(product).find("[data-low-stock-check]")
  def qty_for(product) = row_for(product).find("[data-low-stock-quantity]")
  def select_all = modal.find("[data-low-stock-select-all]")
  def add_button = modal.find("[data-low-stock-add]")
  def summary = modal.find("[data-low-stock-summary]").text
  def indeterminate? = page.evaluate_script("document.querySelector('[data-low-stock-select-all]').indeterminate")
  def lines = all("table.line-items-table tbody tr[data-line-row]")
  def line_products = lines.map { |tr| tr.find("select[name*='[product_id]']", visible: :all).value }.compact_blank

  def open_picker(locale: "en")
    owner.update!(preferred_locale: locale)
    sign_in owner
    visit new_inventory_purchase_request_path
    click_button form(:add_from_low_stock, locale: locale)
    expect(page).to have_css("[data-purchase-request-form-target='lowStockModal'] [data-low-stock-row]")
  end

  it "selects all, deselects all, shows the indeterminate state and keeps the count and Add label in step" do
    open_picker

    expect(summary).to eq(form(:low_stock_none_selected))
    expect(add_button).to be_disabled
    expect(add_button.text).to eq(form(:add_selected_count, count: 0))

    select_all.check
    expect([ check_for(alpha), check_for(beta), check_for(gamma) ]).to all(be_checked)
    expect(summary).to eq(form(:low_stock_selected_count, count: 3))
    expect(add_button.text).to eq(form(:add_selected_count, count: 3))
    expect(indeterminate?).to be(false)

    check_for(beta).uncheck
    expect(select_all).not_to be_checked
    expect(indeterminate?).to be(true)
    expect(summary).to eq(form(:low_stock_selected_count, count: 2))

    select_all.check # from indeterminate: selects the rest
    expect(summary).to eq(form(:low_stock_selected_count, count: 3))

    select_all.uncheck
    expect([ check_for(alpha), check_for(beta), check_for(gamma) ]).to all(satisfy { |c| !c.checked? })
    expect(summary).to eq(form(:low_stock_none_selected))
    expect(add_button).to be_disabled
    expect(indeterminate?).to be(false)
  end

  it "keeps entered quantities across (de)selection, and adds the selected rows with them" do
    open_picker

    expect(qty_for(beta).value).to eq("12") # the suggested reorder quantity
    qty_for(beta).fill_in(with: "7")
    check_for(beta).check
    check_for(beta).uncheck
    check_for(beta).check
    expect(qty_for(beta).value).to eq("7")
    check_for(gamma).check

    add_button.click
    expect(page).to have_no_css("[data-purchase-request-form-target='lowStockModal'] [data-low-stock-row]", visible: true)
    expect(line_products).to contain_exactly(beta.id.to_s, gamma.id.to_s)
    beta_line = lines.find { |tr| tr.find("select[name*='[product_id]']", visible: :all).value == beta.id.to_s }
    expect(beta_line.find("input[name*='[entered_quantity]']").value).to eq("7")
  end

  it "blocks invalid quantities and stays open; Cancel and Escape close it, a click outside does not" do
    open_picker
    check_for(alpha).check
    qty_for(alpha).fill_in(with: "0")

    expect(modal).to have_css("[data-low-stock-invalid]", visible: true, text: form(:low_stock_invalid_quantity))
    expect(qty_for(alpha)["aria-invalid"]).to eq("true")
    expect(add_button).to be_disabled
    qty_for(alpha).fill_in(with: "-3")
    expect(add_button).to be_disabled

    qty_for(alpha).fill_in(with: "4")
    expect(modal).to have_no_css("[data-low-stock-invalid]", visible: true)
    expect(add_button).not_to be_disabled

    page.execute_script("document.querySelector('[data-purchase-request-form-target=\"lowStockModal\"]').click()")
    expect(page).to have_css("[data-purchase-request-form-target='lowStockModal'] [data-low-stock-row]", visible: true)

    modal.click_button I18n.t("common.cancel")
    expect(page).to have_no_css("[data-purchase-request-form-target='lowStockModal'] [data-low-stock-row]", visible: true)
    expect(line_products).to be_empty

    click_button form(:add_from_low_stock)
    find("body").send_keys(:escape)
    expect(page).to have_no_css("[data-purchase-request-form-target='lowStockModal'] [data-low-stock-row]", visible: true)
  end

  it "does not offer a product already on the request (no badge), and never adds it twice" do
    open_picker
    check_for(beta).check
    add_button.click

    click_button form(:add_from_low_stock)
    expect(modal).to have_no_css("[data-low-stock-row][data-product-id='#{beta.id}']", visible: true)
    expect(modal).to have_text(form(:low_stock_hidden_rows, count: 1))
    select_all.check
    expect(summary).to eq(form(:low_stock_selected_count, count: 2)) # only what is offered
    add_button.click

    expect(line_products.tally.values).to all(eq(1))
    expect(line_products).to contain_exactly(alpha.id.to_s, beta.id.to_s, gamma.id.to_s)
  end

  context "with Gamma low only in Other WH" do
    let!(:gamma) { low_product("Gamma Gel", "GA-1", reorder_quantity: 3, warehouse: other_wh) }

    it "keeps one warehouse per request: a warehouse-specific row sets it, rows of another warehouse are not offered" do
      open_picker
      expect(row_for(gamma)["data-warehouse-id"]).to eq(other_wh.id.to_s)
      check_for(gamma).check
      add_button.click
      expect(find("select[name='purchase_request[warehouse_id]']").value).to eq(other_wh.id.to_s)

      select "Main WH", from: "purchase_request[warehouse_id]"
      click_button form(:add_from_low_stock)
      # Gamma is on the request already; a Main WH request can't take Other WH rows either way.
      expect(modal).to have_no_css("[data-low-stock-row][data-product-id='#{gamma.id}']", visible: true)
      expect(row_for(alpha)).to be_visible # a Main WH row fits a Main WH request
    end

    it "shows no Warehouse column (the form chooses it), while the rows keep their warehouse for the one-warehouse rule" do
      %w[en ar].each do |locale|
        open_picker(locale: locale)
        headers = modal.all(".lsp__table thead th").map { |th| th.text.strip }
        expect(headers.size).to eq(5) # checkbox, product, current stock, minimum, suggested quantity
        expect(headers).not_to include(I18n.t("inventory.dashboard.warehouse", locale: locale).upcase,
                                       I18n.t("inventory.dashboard.warehouse", locale: locale))
        expect(modal.all(".lsp__table tbody tr:not([hidden])").map { |tr| tr.all("td").size }.uniq).to eq([ 5 ])
        expect(modal).to have_no_text(other_wh.name)
        expect(row_for(gamma)["data-warehouse-id"]).to eq(other_wh.id.to_s)
        modal.click_button I18n.t("common.cancel", locale: locale)
      end

      # The rule itself is unchanged: with Main WH chosen, the Other WH row is not offered.
      select "Main WH", from: "purchase_request[warehouse_id]"
      click_button form(:add_from_low_stock, locale: "ar")
      expect(modal).to have_no_css("[data-low-stock-row][data-product-id='#{gamma.id}']", visible: true)
      expect(modal).to have_text(form(:low_stock_hidden_rows, count: 1, locale: "ar"))
    end
  end

  it "highlights out-of-stock products" do
    open_picker
    expect(row_for(alpha)["data-out-of-stock"]).to eq("true")
    expect(row_for(alpha)).to have_css(".lsp__stock--out", text: "0")
    expect(row_for(alpha)).to have_css(".sr-only", text: form(:low_stock_out_of_stock), visible: :all)
    expect(row_for(beta)).to have_no_css(".lsp__stock--out")
  end

  it "AR: right-to-left layout, Arabic title and labels, sticky header and footer, and the same interaction" do
    open_picker(locale: "ar")

    expect(page).to have_css("html[dir='rtl']")
    expect(modal).to have_css("#low-stock-picker-title", text: "اختيار منتجات من المخزون المنخفض")
    expect(modal).to have_no_text("مضاف")
    expect(modal).to have_no_text("مستودع آخر")
    expect(page.evaluate_script("getComputedStyle(document.querySelector('.lsp__table thead th')).position")).to eq("sticky")
    footer_inside = page.evaluate_script(<<~JS)
      (function() {
        const card = document.querySelector('.modal-card.lsp').getBoundingClientRect();
        const foot = document.querySelector('.lsp__footer').getBoundingClientRect();
        return foot.bottom <= card.bottom + 1 && foot.top >= card.top;
      })()
    JS
    expect(footer_inside).to be(true)
    # The checkbox column sits on the right in RTL.
    rtl_order = page.evaluate_script(<<~JS)
      (function() {
        const cells = document.querySelectorAll('.lsp__table tbody tr:not([hidden]) td');
        return cells[0].getBoundingClientRect().left > cells[1].getBoundingClientRect().left;
      })()
    JS
    expect(rtl_order).to be(true)

    expect(summary).to eq(form(:low_stock_none_selected, locale: "ar"))
    select_all.check
    expect(summary).to eq(form(:low_stock_selected_count, count: 3, locale: "ar"))
    expect(add_button.text).to eq(form(:add_selected_count, count: 3, locale: "ar"))
    add_button.click
    expect(line_products).to contain_exactly(alpha.id.to_s, beta.id.to_s, gamma.id.to_s)
  end
end
