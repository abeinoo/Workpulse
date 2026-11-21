require "rails_helper"

# The searchable product picker (product-combobox) on the inventory screens:
# server search by name / SKU / barcode with thumbnails, keyboard (↓ ↑ Enter
# Escape), clearing, empty results, several pickers on one form, the workflow
# listeners it feeds (supplier pre-fill, barcode scanner, saving), RTL, and the
# report / dashboard pickers — all without loading the catalogue into the page.
RSpec.describe "Searchable product picker", type: :system do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let!(:warehouse) { business.warehouses.create!(name: "Main") }
  let!(:acme)      { business.suppliers.create!(name: "Acme") }
  let!(:argan) do
    business.products.create!(name: "Argan Oil", sku: "AO-100", average_cost_price: 12, default_supplier: acme).tap do |p|
      attach_product_image!(p)
    end
  end
  let!(:mask) do
    business.products.create!(name: "Hair Mask", sku: "MK-200", average_cost_price: 20)
            .tap { |p| p.product_barcodes.create!(barcode: "6281000099991", is_primary: true) }
  end
  let!(:comb) { business.products.create!(name: "Wide Comb", sku: "CB-300", average_cost_price: 3) }

  def rows = all("tr[data-line-row]:not([hidden])")
  def picker_input(row) = row.find("[data-product-combobox-target='input']")
  def product_value(row) = row.find("select[data-product-field]", visible: :all).value
  def listbox_open = find(".pcombo__listbox", visible: true)

  def search(row, text)
    input = picker_input(row)
    page.execute_script("arguments[0].scrollIntoView({ block: 'center' })", input.native)
    input.click
    input.fill_in(with: text)
  end

  def new_receipt
    sign_in owner
    visit new_inventory_goods_receipt_path
    click_button "+ #{I18n.t('inventory.goods_receipts.add_item')}" if rows.empty?
  end

  it "searches by name, SKU and barcode, with thumbnails, and an empty state" do
    new_receipt
    row = rows.first

    search(row, "argan")
    expect(listbox_open).to have_css(".pcombo__option", count: 1, text: "Argan Oil")
    expect(listbox_open.find(".pcombo__option", text: "Argan Oil")).to have_css(".pthumb img.pthumb__img", visible: :all)
    expect(listbox_open.find(".pcombo__option mark").text.downcase).to eq("argan") # the match is marked

    search(row, "MK-2")
    expect(listbox_open).to have_css(".pcombo__option", count: 1, text: "Hair Mask")
    expect(listbox_open.find(".pcombo__option")).to have_css(".pthumb--empty") # no image → placeholder

    search(row, "62810000")
    expect(listbox_open).to have_css(".pcombo__option", text: "Hair Mask")
    expect(listbox_open).to have_text("6281000099991")

    search(row, "nothing-like-this")
    expect(listbox_open).to have_css(".pcombo__status",
                                     text: I18n.t("inventory.product_picker.empty", query: "nothing-like-this"))
  end

  it "keyboard: ↓ / Enter choose, Escape and a click outside keep the selection; × clears" do
    new_receipt
    row = rows.first
    search(row, "o") # Argan Oil, Wide Comb
    expect(listbox_open).to have_css(".pcombo__option", count: 2)
    picker_input(row).send_keys(:down)
    expect(find(".pcombo__option.is-active")).to have_text("Wide Comb")
    expect(picker_input(row)["aria-activedescendant"]).to eq(find(".pcombo__option.is-active")["id"])
    picker_input(row).send_keys(:enter)

    expect(page).to have_no_css(".pcombo__listbox", visible: true)
    expect(product_value(row)).to eq(comb.id.to_s)
    expect(picker_input(row).value).to eq("Wide Comb")
    expect(row).to have_css(".pcombo__thumb .pthumb--empty")

    search(row, "argan")
    picker_input(row).send_keys(:escape)
    expect(page).to have_no_css(".pcombo__listbox", visible: true)
    expect(picker_input(row).value).to eq("Wide Comb") # Escape never replaces the selection
    expect(product_value(row)).to eq(comb.id.to_s)

    search(row, "argan")
    find("h1").click # outside
    expect(page).to have_no_css(".pcombo__listbox", visible: true)
    expect(product_value(row)).to eq(comb.id.to_s)

    row.find(".pcombo__clear").click
    expect(product_value(row)).to eq("")
    expect(picker_input(row).value).to eq("")
  end

  it "several pickers on one form work independently; choosing feeds the supplier pre-fill and the receipt saves" do
    new_receipt
    select "Main", from: "goods_receipt[warehouse_id]"
    choose I18n.t("inventory.goods_receipts.funding_source_kinds.supplier_credit")
    click_button "+ #{I18n.t('inventory.goods_receipts.add_item')}"
    first_row, second_row = rows.first(2)

    search(first_row, "argan")
    find(".pcombo__option", text: "Argan Oil").click
    expect(find("select[data-receipt-supplier-target='supplier']").value).to eq(acme.id.to_s) # default supplier pre-fill

    search(second_row, "comb")
    find(".pcombo__option", text: "Wide Comb").click
    expect([ product_value(first_row), product_value(second_row) ]).to eq([ argan.id.to_s, comb.id.to_s ])

    first_row.find("input[name$='[quantity]']").fill_in(with: "2")
    first_row.find("input[name$='[unit_cost]']").fill_in(with: "12")
    second_row.find("input[name$='[quantity]']").fill_in(with: "5")
    second_row.find("input[name$='[unit_cost]']").fill_in(with: "3")
    click_button I18n.t("inventory.goods_receipts.save_draft")

    expect(page).to have_current_path(%r{/inventory/goods_receipts/\d+})
    receipt = GoodsReceipt.last
    expect(receipt.items.map { |i| [ i.product, i.quantity ] }).to contain_exactly([ argan, 2 ], [ comb, 5 ])
    expect(receipt.supplier).to eq(acme)
  end

  it "the barcode scanner adds a product that isn't on the page yet, shown in the picker" do
    new_receipt
    scanner = find("[data-barcode-scanner-target='input']")
    scanner.fill_in(with: "6281000099991")
    scanner.send_keys(:enter)

    # Looked up remotely (async), then its <option> is added and selected.
    expect(page).to have_css("select[data-product-field] option[value='#{mask.id}']", visible: :all)
    row = rows.find { |r| product_value(r) == mask.id.to_s }
    expect(row).to be_present
    expect(picker_input(row).value).to eq("Hair Mask")

    scanner.fill_in(with: "6281000099991") # again: the same line, never a duplicate row
    scanner.send_keys(:enter)
    expect(rows.count { |r| product_value(r) == mask.id.to_s }).to eq(1)
  end

  it "stock adjustment lines use the picker too, and post" do
    sign_in owner
    visit new_inventory_stock_adjustment_path
    select "Main", from: "stock_adjustment[warehouse_id]"
    click_button "+ #{I18n.t('inventory.stock_adjustments.add_item')}" if rows.empty?
    search(rows.first, "CB-300")
    find(".pcombo__option", text: "Wide Comb").click
    rows.first.find("input[name$='[quantity_difference]']").fill_in(with: "4")

    click_button I18n.t("inventory.stock_adjustments.post")
    expect(page).to have_current_path(%r{/inventory/stock_adjustments/\d+})
    expect(StockAdjustment.last.items.map(&:product)).to eq([ comb ])
  end

  it "Arabic RTL: the selected product's thumbnail sits at the start (right) of the field" do
    owner.update!(preferred_locale: "ar")
    new_receipt
    row = rows.first
    search(row, "argan")
    find(".pcombo__option", text: "Argan Oil").click

    rtl = page.evaluate_script(<<~JS, picker_input(row).native)
      (function(input) {
        const thumb = input.parentElement.querySelector(".pcombo__thumb").getBoundingClientRect();
        const box = input.getBoundingClientRect();
        return { dir: getComputedStyle(input).direction, rightSide: thumb.left > box.left + box.width / 2 };
      })(arguments[0])
    JS
    expect(page).to have_css("html[dir='rtl']")
    expect(rtl).to eq("dir" => "rtl", "rightSide" => true)
  end

  it "the inventory dashboard quick search finds a product and opens its card" do
    sign_in owner
    visit inventory_root_path
    input = find(".inv-dash__search [data-product-combobox-target='input']")
    input.click
    input.fill_in(with: "mask")
    find(".pcombo__option", text: "Hair Mask").click

    expect(page).to have_current_path(/product_id=#{mask.id}/)
    expect(page).to have_css(".inv-dash__quick", text: "Hair Mask")
  end

  it "a report filter picks any product (archived too) and keeps it selected after filtering" do
    argan.update!(active: false)
    sign_in owner
    visit inventory_movements_report_path
    input = find("[data-product-combobox-target='input']")
    input.click
    input.fill_in(with: "argan")
    find(".pcombo__option", text: "Argan Oil").click
    find("form.filter-bar").find("button[type='submit'], input[type='submit']", match: :first).click

    expect(page).to have_current_path(/product_id=#{argan.id}/)
    expect(find("[data-product-combobox-target='input']").value).to eq("Argan Oil")
  end
end
