require "rails_helper"

# The Measure in a real browser: chosen on the product form as information
# about the product, and never shown as the unit of a document line's quantity
# (a number of inventory units) — English and Arabic (RTL).
RSpec.describe "Product measure (browser)", type: :system do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let!(:warehouse) { business.warehouses.create!(name: "Main", kind: "central") }
  let!(:shampoo) { business.products.create!(name: "Argan Shampoo", sku: "SH-1", average_cost_price: 2, unit_of_measure: "ml") }
  let!(:dye)     { business.products.create!(name: "Hair Dye", sku: "DY-1", average_cost_price: 5, unit_of_measure: "g") }

  def rows = all("tr[data-line-row]")
  def pick(row, text, name)
    input = row.find("[data-product-combobox-target='input']")
    page.execute_script("arguments[0].scrollIntoView({ block: 'center' })", input.native)
    input.click
    input.fill_in(with: text)
    find(".pcombo__listbox", visible: true).find(".pcombo__option", text: name).click
  end

  %w[en ar].each do |locale|
    it "a goods receipt line's quantity carries no measure, whichever product is picked (#{locale})" do
      owner.update!(preferred_locale: locale)
      sign_in owner
      visit new_inventory_goods_receipt_path
      click_button "+ #{I18n.t('inventory.goods_receipts.add_item', locale: locale)}" if rows.empty?
      row = rows.first

      pick(row, "SH-1", "Argan Shampoo")
      expect(row).to have_no_css("[data-measure-label], .qty-unit")
      expect(row.find("[data-quantity-field]")).to be_present
      pick(row, "DY-1", "Hair Dye")
      expect(row).to have_no_css("[data-measure-label], .qty-unit")
    end
  end

  { "en" => "ltr", "ar" => "rtl" }.each do |locale, dir|
    it "Measure then Amount, side by side; a decimal amount is saved and shown back (#{locale}, #{dir})" do
      owner.update!(preferred_locale: locale)
      sign_in owner
      visit edit_inventory_product_path(dye)
      amount  = find("[data-testid='product-measure-amount']")
      measure = find("[data-testid='product-measure']")
      a = page.evaluate_script("arguments[0].getBoundingClientRect().toJSON()", amount.native)
      m = page.evaluate_script("arguments[0].getBoundingClientRect().toJSON()", measure.native)
      expect((a["top"] - m["top"]).abs).to be < 4                 # same row
      dir == "ltr" ? expect(m["right"]).to(be <= a["left"] + 1) : expect(m["left"]).to(be >= a["right"] - 1) # Measure first

      amount.fill_in(with: "0.5")
      measure.select(I18n.t("inventory.measures.kg.name", locale: locale))
      find("[data-testid='product-save']").click
      expect(page).to have_text(I18n.t("inventory.products.all_saved", locale: locale))
      expect([ dye.reload.measure_amount, dye.unit_of_measure ]).to eq([ BigDecimal("0.5"), "kg" ])
      expect(find("[data-testid='product-measure']").text).to include("0.5 #{I18n.t('inventory.measures.kg.short', locale: locale)}")

      visit edit_inventory_product_path(dye)
      expect(find("[data-testid='product-measure-amount']").value).to eq("0.5")
    end
  end

  it "the product form's Measure is saved and shown back on Edit" do
    sign_in owner
    visit edit_inventory_product_path(shampoo)
    expect(page).to have_select("product[unit_of_measure]", selected: "Millilitres (ml)")
    select "Litres (l)", from: "product[unit_of_measure]"
    find("[data-testid='product-save']").click
    expect(page).to have_text("All changes saved.")
    expect(shampoo.reload.unit_of_measure).to eq("l")
    visit edit_inventory_product_path(shampoo)
    expect(page).to have_select("product[unit_of_measure]", selected: "Litres (l)")
  end
end
