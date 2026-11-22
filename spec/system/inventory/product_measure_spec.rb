require "rails_helper"

# The Measure in a real browser: chosen on the product form, and shown beside a
# document line's quantity the moment the line's product is picked (and changed
# when another product is picked) — English and Arabic (RTL).
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

  { "en" => %w[ml g], "ar" => %w[مل غ] }.each do |locale, (ml, grams)|
    it "a goods receipt line shows the picked product's measure and follows a change of product (#{locale})" do
      owner.update!(preferred_locale: locale)
      sign_in owner
      visit new_inventory_goods_receipt_path
      click_button "+ #{I18n.t('inventory.goods_receipts.add_item', locale: locale)}" if rows.empty?
      row = rows.first

      pick(row, "SH-1", "Argan Shampoo")
      expect(row).to have_css("[data-measure-label]", text: ml, exact_text: true)
      pick(row, "DY-1", "Hair Dye")
      expect(row).to have_css("[data-measure-label]", text: grams, exact_text: true)
    end
  end

  { "en" => "ltr", "ar" => "rtl" }.each do |locale, dir|
    it "Amount sits beside Measure; a decimal amount is saved and shown back (#{locale}, #{dir})" do
      owner.update!(preferred_locale: locale)
      sign_in owner
      visit edit_inventory_product_path(dye)
      amount  = find("[data-testid='product-measure-amount']")
      measure = find("[data-testid='product-measure']")
      a = page.evaluate_script("arguments[0].getBoundingClientRect().toJSON()", amount.native)
      m = page.evaluate_script("arguments[0].getBoundingClientRect().toJSON()", measure.native)
      expect((a["top"] - m["top"]).abs).to be < 4                 # same row
      dir == "ltr" ? expect(a["right"]).to(be <= m["left"] + 1) : expect(a["left"]).to(be >= m["right"] - 1)

      amount.fill_in(with: "0.5")
      measure.select(I18n.t("inventory.measures.kg.name", locale: locale))
      find("[data-testid='product-save']").click
      expect(page).to have_text(I18n.t("inventory.products.updated", locale: locale))
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
    expect(page).to have_text("Product updated.")
    expect(shampoo.reload.unit_of_measure).to eq("l")
    visit edit_inventory_product_path(shampoo)
    expect(page).to have_select("product[unit_of_measure]", selected: "Litres (l)")
  end
end
