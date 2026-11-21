require "rails_helper"

# The Product Edit image gallery in a real browser: several photos uploaded in
# one selection (previewed, staged with progress), the primary image chosen,
# photos reordered (buttons and drag and drop) and removed after confirmation,
# all applied on Save — in English (LTR) and Arabic (RTL), desktop and phone.
RSpec.describe "Product Edit — image gallery (browser)", type: :system do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let!(:product) { business.products.create!(name: "Argan Oil", sku: "AO-1", initial_cost_price: 4, average_cost_price: 4) }
  let(:png)      { ProductImageHelpers::TEST_IMAGE.to_s }

  after { page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") }

  def emulate(width) = page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                                      width: width, height: 1000, deviceScaleFactor: 1, mobile: width < 768)

  def visit_edit(locale: "en", width: 1440)
    owner.update!(preferred_locale: locale)
    sign_in owner
    emulate(width)
    visit edit_inventory_product_path(product)
  end

  def items = all("ol.pgallery__thumbs > li")
  def entries = items.map { |li| li["data-entry"] }
  def submitted = all("input[name='product[gallery][]']", visible: :all).map(&:value)
  def save! = find("[data-testid='product-save'], #product-form [type='submit']", match: :first).click

  it "uploads several photos in one selection, previews them, and saves them in order" do
    visit_edit
    expect(page).to have_css("[data-testid='gallery-empty']")
    find("[data-testid='gallery-file-input']", visible: :all).attach_file([ png, png ], make_visible: true)

    expect(page).to have_css("ol.pgallery__thumbs > li", count: 2)
    expect(page).to have_no_css("ol.pgallery__thumbs > li.is-uploading", wait: 10)
    expect(entries).to all(start_with("upload:"))
    expect(page).to have_css("[data-testid='gallery-main'] img")
    expect(submitted).to eq(entries)
    expect(ProductImage.count).to eq(0) # nothing applied before Save

    save!
    expect(page).to have_text(I18n.t("inventory.products.updated"))
    expect(product.images.reload.map(&:position)).to eq([ 1, 2 ])
  end

  it "chooses the primary image, reorders with the buttons, removes after confirmation — applied on Save" do
    a = attach_product_image!(product)
    b = attach_product_image!(product)
    c = attach_product_image!(product)
    visit_edit

    within(items[2]) { find("[data-role='make-primary']").click }
    expect(entries).to eq([ "image:#{c.id}", "image:#{a.id}", "image:#{b.id}" ])
    expect(items.first[:class]).to include("is-primary")

    within(items[1]) { click_button I18n.t("inventory.products.gallery.move_later") }
    expect(entries).to eq([ "image:#{c.id}", "image:#{b.id}", "image:#{a.id}" ])

    dismiss_confirm { within(items[1]) { find("[data-testid='gallery-remove']").click } }
    expect(items.size).to eq(3)
    accept_confirm(I18n.t("inventory.products.gallery.remove_confirm")) { within(items[1]) { find("[data-testid='gallery-remove']").click } }
    expect(entries).to eq([ "image:#{c.id}", "image:#{a.id}" ])
    expect(ProductImage.where(id: [ a.id, b.id, c.id ]).count).to eq(3) # still saved until Save

    save!
    expect(page).to have_text(I18n.t("inventory.products.updated"))
    expect(product.images.reload.map(&:id)).to eq([ c.id, a.id ])
    expect(ProductImage.exists?(b.id)).to be(false)
  end

  it "reorders by drag and drop" do
    a = attach_product_image!(product)
    b = attach_product_image!(product)
    visit_edit

    page.execute_script(<<~JS)
      const [first, second] = document.querySelectorAll("ol.pgallery__thumbs > li")
      const data = new DataTransfer()
      const fire = (el, type, x) => el.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, dataTransfer: data, clientX: x }))
      const box = second.getBoundingClientRect()
      fire(first, "dragstart", 0)
      fire(second, "dragover", box.right - 2)
      fire(second, "drop", box.right - 2)
      fire(first, "dragend", 0)
    JS
    expect(entries).to eq([ "image:#{b.id}", "image:#{a.id}" ])
    expect(submitted).to eq([ "image:#{b.id}", "image:#{a.id}" ])
  end

  it "rejects a file that is not an image before uploading, with a message" do
    text = Tempfile.new([ "notes", ".txt" ]).tap { |f| f.write("hello"); f.flush }
    visit_edit
    find("[data-testid='gallery-file-input']", visible: :all).attach_file(text.path, make_visible: true)
    expect(page).to have_css("[data-testid='gallery-errors']", text: I18n.t("inventory.products.gallery.errors.invalid_type"))
    expect(items).to be_empty
  end

  it "keeps the existing photos when the product is saved without touching the gallery" do
    a = attach_product_image!(product)
    visit_edit
    fill_in "product_name", with: "Argan Oil Pro"
    save!
    expect(page).to have_text(I18n.t("inventory.products.updated"))
    expect(product.reload.name).to eq("Argan Oil Pro")
    expect(product.images.map(&:id)).to eq([ a.id ])
  end

  { "en" => "ltr", "ar" => "rtl" }.each do |locale, dir|
    it "sits beside the form on desktop and above it on a phone (#{locale}, #{dir})" do
      attach_product_image!(product)
      visit_edit(locale: locale, width: 1440)
      expect(page.evaluate_script("document.documentElement.dir")).to eq(dir)
      gallery = page.evaluate_script("document.querySelector('.pgallery').getBoundingClientRect().toJSON()")
      form    = page.evaluate_script("document.querySelector('#product-form').getBoundingClientRect().toJSON()")
      if dir == "ltr"
        expect(gallery["left"]).to be > form["right"] - 1   # gallery on the right
      else
        expect(gallery["right"]).to be < form["left"] + 1   # mirrored: gallery on the left
      end
      expect(page).to have_text(I18n.t("inventory.products.gallery.add_photos", locale: locale))

      emulate(390)
      visit edit_inventory_product_path(product)
      gallery = page.evaluate_script("document.querySelector('.pgallery').getBoundingClientRect().toJSON()")
      form    = page.evaluate_script("document.querySelector('#product-form').getBoundingClientRect().toJSON()")
      expect(gallery["bottom"]).to be <= form["top"] + 1    # above the details
      expect(page.evaluate_script("document.documentElement.scrollWidth")).to be <= 390
    end
  end
end
