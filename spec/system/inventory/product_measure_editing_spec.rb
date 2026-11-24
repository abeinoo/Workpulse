require "rails_helper"

# Unit of Measure + Amount in a real browser, English (LTR) and Arabic (RTL):
# the Amount follows the selected unit without a reload — hidden and cleared
# for pieces, shown with the unit as its suffix otherwise — and both save
# directly, also on a product with stock history (no conversion step).
RSpec.describe "Product measure editing (browser)", type: :system do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let!(:main)    { business.warehouses.create!(name: "Main", kind: "central") }
  let!(:product) { business.products.create!(name: "Masque", sku: "VM-1", initial_cost_price: 0, average_cost_price: 0) }

  def measure = find("[data-testid='product-measure']")
  def amount  = find("[data-testid='product-measure-amount']")
  def name_of(code, locale) = I18n.t("inventory.measures.#{code}.name", locale: locale)
  def short(code, locale) = I18n.t("inventory.measures.#{code}.short", locale: locale)
  def suffix?(text) = have_css("[data-testid='product-measure-amount-suffix']", exact_text: text)
  def save! = find("[data-testid='product-save']").click

  { "en" => "ltr", "ar" => "rtl" }.each do |locale, dir|
    context "in #{locale} (#{dir})" do
      before do
        owner.update!(preferred_locale: locale)
        sign_in owner
      end

      it "switching the unit updates the Amount at once and never keeps a stale value" do
        visit edit_inventory_product_path(product)
        expect(page.evaluate_script("getComputedStyle(arguments[0]).direction", measure.native)).to eq(dir)
        expect(page).to have_no_css("[data-testid='product-measure-amount-group']") # pieces: no Amount

        measure.select(name_of("ml", locale))
        expect(page).to suffix?(short("ml", locale))
        amount.fill_in(with: "355")
        measure.select(name_of("g", locale))
        expect(page).to suffix?(short("g", locale))
        expect(amount.value).to eq("355")                                            # kept between measured units

        measure.select(name_of("pieces", locale))
        expect(page).to have_no_css("[data-testid='product-measure-amount-group']")
        measure.select(name_of("cm", locale))
        expect(page).to suffix?(short("cm", locale))
        expect(amount.value).to eq("")                                               # cleared by pieces

        amount.fill_in(with: "60")
        save!
        expect(page).to have_text(I18n.t("inventory.products.all_saved", locale: locale))
        expect([ product.reload.unit_of_measure, product.measure_amount ]).to eq([ "cm", 60 ])

        visit edit_inventory_product_path(product)
        measure.select(name_of("pieces", locale))
        save!
        expect(page).to have_text(I18n.t("inventory.products.all_saved", locale: locale))
        expect([ product.reload.unit_of_measure, product.measure_amount ]).to eq([ "pieces", nil ])
      end

      it "with stock history the unit and amount save directly; stock is unchanged" do
        receipt = business.goods_receipts.build(warehouse: main, received_on: Date.current)
        receipt.items.build(product: product, quantity: 10, unit_cost: 6)
        Inventory::GoodsReceiptPoster.new(receipt, actor: owner).call

        visit edit_inventory_product_path(product)
        expect(page).to have_no_css("[data-testid='unit-change'], [data-testid='packaging-section']")
        measure.select(name_of("cm", locale))
        amount.fill_in(with: "60")
        save!
        expect(page).to have_text(I18n.t("inventory.products.all_saved", locale: locale))
        expect([ product.reload.unit_of_measure, product.measure_amount, product.current_stock ]).to eq([ "cm", 60, 10 ])
      end
    end
  end
end
