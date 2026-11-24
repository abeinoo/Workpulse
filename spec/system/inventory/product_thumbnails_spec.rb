require "rails_helper"

# Product thumbnails in the browser: the real variant loads into a fixed-size
# box (fitted, never stretched), a product without an image shows the
# placeholder, an image that fails to load becomes the placeholder (never a
# broken image), RTL puts the thumbnail on the right, and the product picker's
# search results show thumbnails.
RSpec.describe "Product thumbnails", type: :system do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let!(:warehouse) { business.warehouses.create!(name: "Main") }
  let!(:with_image) do
    business.products.create!(name: "Argan Oil", sku: "AO-1", average_cost_price: 5).tap do |p|
      attach_product_image!(p)
    end
  end
  let!(:without_image) { business.products.create!(name: "Comb", sku: "CB-1", average_cost_price: 2) }

  def wait_until(seconds = Capybara.default_max_wait_time * 2)
    deadline = Time.current + seconds
    sleep 0.1 until yield || Time.current > deadline
  end

  def box_metrics(selector)
    page.evaluate_script(<<~JS)
      (function() {
        const box = document.querySelector(#{selector.to_json});
        const r = box.getBoundingClientRect(); const img = box.querySelector("img");
        return { w: Math.round(r.width), h: Math.round(r.height), empty: box.classList.contains("pthumb--empty"),
                 loaded: !!(img && img.complete && img.naturalWidth > 0),
                 fit: img ? getComputedStyle(img).objectFit : null };
      })()
    JS
  end

  it "loads the image fitted into a fixed box, and shows the placeholder without one (Arabic RTL)" do
    owner.update!(preferred_locale: "ar")
    sign_in owner
    visit inventory_products_path

    expect(page).to have_css("html[dir='rtl']")
    expect(page).to have_css("tr[data-product-id], tr", text: "Argan Oil")
    image_box = "tr:has(a[href='/inventory/products/#{with_image.id}']) .pthumb"
    wait_until { box_metrics(image_box)["loaded"] } # the variant is processed on first request
    metrics = box_metrics(image_box)
    # The Products index row thumbnail: a fixed 60px box on desktop
    # (.products-table .product-cell .pthumb; 48px under the mobile breakpoint).
    expect(metrics).to include("w" => 60, "h" => 60, "empty" => false, "loaded" => true, "fit" => "contain")

    placeholder = box_metrics("tr:has(a[href='/inventory/products/#{without_image.id}']) .pthumb")
    expect(placeholder).to include("w" => 60, "h" => 60, "empty" => true, "loaded" => false)

    # RTL: the thumbnail sits to the right of (before) the name.
    rtl = page.evaluate_script(<<~JS)
      (function() {
        const cell = document.querySelector("tr:has(a[href='/inventory/products/#{with_image.id}']) .product-cell");
        return cell.querySelector(".pthumb").getBoundingClientRect().left > cell.querySelector(".product-cell__name").getBoundingClientRect().left;
      })()
    JS
    expect(rtl).to be(true)
  end

  it "replaces an image that fails to load with the placeholder — never a broken image" do
    # The stored file is gone: the image request fails on the server (expected
    # here — not re-raised into the test), and the page must cope.
    original = Capybara.raise_server_errors
    Capybara.raise_server_errors = false
    blob = with_image.primary_image.file.blob
    blob.service.delete(blob.key)
    sign_in owner
    visit inventory_products_path

    image_box = "tr:has(a[href='/inventory/products/#{with_image.id}']) .pthumb"
    expect(page).to have_css("#{image_box}.pthumb--empty")
    expect(page).to have_no_css("#{image_box} img")
  ensure
    page.server.reset_error! # the expected image failure, not a test error
    Capybara.raise_server_errors = original
  end

  it "shows thumbnails in the product picker's search results" do
    sign_in owner
    visit new_inventory_purchase_request_path

    first("tr[data-line-row] [data-product-combobox-target='input']").click
    expect(page).to have_css(".pcombo__option", text: "Argan Oil")
    expect(find(".pcombo__option", text: "Argan Oil")).to have_css(".pthumb--sm img.pthumb__img", visible: :all)
    expect(find(".pcombo__option", text: "Comb")).to have_css(".pthumb--sm.pthumb--empty")
  end
end
