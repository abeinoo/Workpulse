require "rails_helper"

# Deleting barcodes on Product Edit in a real browser. Visibility is checked
# as the user SEES it (Capybara visible: true = rendered, not merely carrying a
# [hidden] attribute), and every deletion is checked in the DATABASE after
# Save — never just by the empty-state text.
RSpec.describe "Product Edit — barcode deletion (browser)", type: :system do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business, preferred_locale: locale) }
  let(:locale)   { "en" }
  let!(:product) { business.products.create!(name: "Foot Scrubber", sku: "NNR-1", initial_cost_price: 45, average_cost_price: 45) }

  def barcode!(code, primary: false, type: "manufacturer")
    product.product_barcodes.create!(barcode: code, barcode_type: type, is_primary: primary)
  end

  def row_css = "[data-line-items-target='rows'] .barcode-list__row"
  def visible_rows = all(row_css, visible: true)
  def visible_values = visible_rows.map { |row| row.find("input[name$='[barcode]']").value }
  def empty_state = find("[data-line-items-target='emptyState']", visible: :all)
  def remove(row) = row.find("button[data-action='line-items#remove']").click
  def save! = find("[data-testid='product-save']").click
  def saved_barcodes = ProductBarcode.where(product_id: product.id).order(:id).pluck(:barcode)

  before { sign_in owner }

  context "in Arabic (the reported screen)" do
    let(:locale) { "ar" }

    it "one saved barcode: × hides it, shows the empty state, Save destroys the record, reopening shows none" do
      saved = barcode!("10000005", primary: true, type: "internal")
      visit edit_inventory_product_path(product)
      expect(visible_values).to eq(%w[10000005])
      expect(empty_state).not_to be_visible

      remove(visible_rows.first)
      expect(page).to have_no_css(row_css, visible: true)            # gone from the screen, not just [hidden]
      expect(empty_state).to be_visible
      expect(empty_state.text).to eq(I18n.t("inventory.products.no_barcodes", locale: "ar"))
      expect(ProductBarcode.exists?(saved.id)).to be(true)           # nothing written before Save

      save!
      expect(page).to have_text(I18n.t("inventory.products.updated", locale: "ar"))
      expect(ProductBarcode.exists?(saved.id)).to be(false)          # the record itself is destroyed
      expect(saved_barcodes).to be_empty

      visit edit_inventory_product_path(product)
      expect(page).to have_no_css(row_css, visible: true)
      expect(empty_state).to be_visible
    end
  end

  it "deletes one of several barcodes, keeping the others" do
    barcode!("111", primary: true)
    barcode!("222")
    barcode!("333")
    visit edit_inventory_product_path(product)
    remove(visible_rows[1])
    expect(visible_values).to eq(%w[111 333])
    expect(empty_state).not_to be_visible
    save!
    expect(page).to have_text("Product updated.")
    expect(saved_barcodes).to eq(%w[111 333])
  end

  it "deletes the primary barcode; no other one is made primary" do
    barcode!("111", primary: true)
    barcode!("222")
    visit edit_inventory_product_path(product)
    remove(visible_rows.first)
    expect(visible_values).to eq(%w[222])
    save!
    expect(page).to have_text("Product updated.")
    expect(ProductBarcode.where(product_id: product.id).pluck(:barcode, :is_primary)).to eq([ [ "222", false ] ])
  end

  it "deletes every barcode: the product is saved with zero barcode records" do
    barcode!("111", primary: true)
    barcode!("222")
    visit edit_inventory_product_path(product)
    2.times { remove(visible_rows.first) }
    expect(page).to have_no_css(row_css, visible: true)
    expect(empty_state).to be_visible
    save!
    expect(page).to have_text("Product updated.")
    expect(saved_barcodes).to be_empty
    expect(product.reload).to be_valid
  end

  it "a barcode added then removed before Save leaves no record" do
    barcode!("111", primary: true)
    visit edit_inventory_product_path(product)
    click_button I18n.t("inventory.products.add_barcode")
    expect(page).to have_css(row_css, visible: true, count: 2)
    visible_rows.last.find("input[name$='[barcode]']").fill_in(with: "999")
    remove(visible_rows.last)
    expect(visible_values).to eq(%w[111])
    expect { save!; expect(page).to have_text("Product updated.") }.not_to change(ProductBarcode, :count)
    expect(saved_barcodes).to eq(%w[111])
  end

  it "a refused Save keeps the deletion pending (still hidden, still marked) and deletes nothing; fixing and saving deletes it" do
    barcode!("111", primary: true)
    doomed = barcode!("222")
    visit edit_inventory_product_path(product)
    remove(visible_rows.last)
    fill_in "product_name", with: ""
    save!
    expect(page).to have_css(".form-error", text: /name/i) # the refused save's message
    expect(ProductBarcode.exists?(doomed.id)).to be(true)             # nothing deleted by the refused save
    expect(visible_values).to eq(%w[111])                              # the pending deletion is still hidden
    marked = all("input[name$='[_destroy]']", visible: :all).select { |input| input.value == "1" }
    expect(marked.size).to eq(1)                                       # and still marked — _destroy not lost

    fill_in "product_name", with: "Foot Scrubber"
    save!
    expect(page).to have_text("Product updated.")
    expect(saved_barcodes).to eq(%w[111])
  end
end
