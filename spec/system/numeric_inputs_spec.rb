require "rails_helper"

# App-wide numeric input standard (input[type="number"] in application.css +
# config/initializers/number_field_inputmode.rb), checked in the browser on RTL
# pages: no native spinners, LTR digits right-aligned, tabular figures, strong
# value vs. faint placeholder, non-shifting focus ring, the right mobile
# keypad, and no clipping / horizontal scroll on phones. Business behaviour
# (validation, precision) is untouched — the values typed are submitted as-is.
#
# Set SCREENSHOT_DIR=/some/dir to also save screenshots.
RSpec.describe "Numeric inputs (RTL, browser)", type: :system do
  let(:business)  { create(:business, currency: "EGP") }
  let(:owner)     { create(:user, :owner, business: business, preferred_locale: "ar") }
  let(:supplier)  { business.suppliers.create!(name: "مورد مستحضرات") }
  let(:warehouse) { business.warehouses.create!(name: "المستودع الرئيسي") }
  let!(:shampoo)  { business.products.create!(name: "شامبو", sku: "SH-1", average_cost_price: 56) }

  def set_viewport(width, height = 1600)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: width, height: height, deviceScaleFactor: 1, mobile: width < 768)
  end

  def js(script) = page.evaluate_script(script)
  def style(el, prop) = el.evaluate_script("getComputedStyle(this).#{prop}")
  def box(el) = el.evaluate_script("(r => ({ w: r.width, h: r.height, left: r.left, right: r.right }))(this.getBoundingClientRect())")

  def expect_no_overflow
    expect(js("document.documentElement.scrollWidth - document.documentElement.clientWidth")).to be <= 0
  end

  def screenshot(name)
    dir = ENV["SCREENSHOT_DIR"]
    page.save_screenshot(File.join(dir, "#{name}.png")) if dir.present?
  end

  def expect_numeric_standard(input, inputmode:)
    expect(style(input, "direction")).to eq("ltr")
    expect(style(input, "textAlign")).to eq("right")
    expect(style(input, "appearance")).to eq("textfield")
    expect(style(input, "fontVariantNumeric")).to include("tabular-nums")
    expect(input[:inputmode]).to eq(inputmode)
    # Entered value reads stronger than the placeholder.
    if input[:placeholder].present?
      placeholder = input.evaluate_script("getComputedStyle(this, '::placeholder').color")
      expect(placeholder).not_to eq(style(input, "color"))
    end
    expect(style(input, "fontWeight")).to eq("500")
  end

  before { sign_in owner }

  describe "Goods Receipt quantity / unit cost" do
    def qty   = first("input[name$='[quantity]']")
    def cost  = first("input[name$='[unit_cost]']")
    def total = first("[data-line-total]")

    def open_form
      visit new_inventory_goods_receipt_path
      first("select[name$='[product_id]']").find("option", text: /شامبو/).select_option
    end

    it "desktop: integer, decimal, large, replace, delete, tab, focus — readable and stable" do
      set_viewport(1280)
      open_form
      expect(page).to have_css("html[dir='rtl']")
      expect_numeric_standard(qty, inputmode: "decimal")   # step 0.001
      expect_numeric_standard(cost, inputmode: "decimal")  # step 0.0001
      expect(box(qty)["w"]).to be >= 100
      # The whole row (incl. the remove button) fits — no hidden horizontal scroll in the items table.
      expect(js("(w => w.scrollWidth - w.clientWidth)(document.querySelector(\x27.table-wrap--form-cards\x27))")).to be <= 1

      qty.fill_in(with: "24")
      cost.fill_in(with: "56")
      expect(total).to have_text("1,344.00 ج.م")

      qty.fill_in(with: "12.5")                       # decimal kept as typed
      expect(qty.value).to eq("12.5")
      expect(total).to have_text("700.00 ج.م")

      qty.fill_in(with: "12500")                      # large value fits, no resize
      width_before = box(qty)["w"]
      expect(qty.evaluate_script("this.scrollWidth <= this.clientWidth")).to be(true)
      expect(total).to have_text("700,000.00 ج.م")

      qty.execute_script("this.focus(); this.select()") # select all (what Ctrl/Cmd+A does) → replace
      qty.send_keys("7")
      expect(qty.value).to eq("7")

      qty.execute_script("this.select()")             # delete with the keyboard → no total
      qty.send_keys(:backspace)
      expect(total).to have_text("—")

      qty.click
      ring = style(qty, "boxShadow")
      expect(ring).not_to eq("none")                  # visible focus ring
      expect(box(qty)["w"]).to eq(width_before)       # focus doesn't shift layout
      qty.send_keys(:tab)
      expect(js("document.activeElement.name")).to eq(cost[:name])
      screenshot("numeric_gr_1280")
    end

    [ 390, 393 ].each do |width|
      it "phone #{width}px: quantity and cost fully visible, comfortable, no horizontal scroll" do
        set_viewport(width)
        open_form
        qty.fill_in(with: "24")
        cost.fill_in(with: "56")

        expect_no_overflow
        row = first("tr[data-line-row]")
        [ qty, cost ].each do |input|
          b = box(input)
          expect(b["h"]).to be >= 44
          expect(b["w"]).to be > width * 0.6
          expect(b["left"]).to be >= box(row)["left"] - 1
          expect(b["right"]).to be <= box(row)["right"] + 1
        end
        expect(total).to have_text("1,344.00 ج.م")
        screenshot("numeric_gr_#{width}")
      end
    end

    it "an invalid quantity keeps the browser's error state on the field without breaking the row" do
      set_viewport(1280)
      open_form
      qty.fill_in(with: "-3")                         # min is 0
      expect(qty.evaluate_script("this.validity.valid")).to be(false)
      expect_no_overflow
    end
  end

  it "Purchase Request quantity and Expense amount use the same standard" do
    set_viewport(1280)
    visit new_inventory_purchase_request_path
    pr_qty = first("tr[data-line-row] input[data-quantity-field]")
    expect_numeric_standard(pr_qty, inputmode: "decimal")

    visit new_finance_expense_path
    amount = find("#expense_amount")
    expect_numeric_standard(amount, inputmode: "decimal")
    amount.fill_in(with: "1240.5")
    expect(amount.value).to eq("1240.5")
  end
end
