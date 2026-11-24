require "rails_helper"

# The single-product Stock Issue popup ("صرف مخزني", internally Quick Issue) in
# a real browser: opened from a product's row menu, centered (opt-in placement
# of the global modal — other modals stay bottom sheets), never taller than the
# viewport, header and actions reachable while the body scrolls, the product
# fixed, and Notes required only for "Other". Arabic (RTL) and English (LTR),
# desktop and narrow.
RSpec.describe "Stock Issue modal (browser)", type: :system do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :owner, business: business, preferred_locale: locale) }
  let(:locale)    { "en" }
  let!(:branch)   { business.branches.create!(name: "Nasr City", active: true) }
  let!(:warehouse) { branch_warehouse_for(branch, name: "Main") }
  let!(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
  end

  before do
    receipt = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    receipt.items.build(product: product, quantity: 10, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(receipt).call
    sign_in owner
  end

  after { page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") }

  def set_viewport(width, height)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: width, height: height, deviceScaleFactor: 1, mobile: width < 768)
  end

  def rect(selector)
    page.evaluate_script(<<~JS)
      (() => { const r = document.querySelector(#{selector.to_json}).getBoundingClientRect();
               return { top: r.top, bottom: r.bottom, left: r.left, right: r.right }; })()
    JS
  end

  def viewport = page.evaluate_script("({ width: window.innerWidth, height: window.innerHeight })")

  # The global modal panel (layouts/application) — the scroll container.
  def panel_selector = "#modal-overlay > div"

  def open_from_row
    visit inventory_products_path
    find("[data-testid='product-row-actions']", match: :first).click
    find("[data-testid='product-quick-issue']").click
    expect(page).to have_css("#modal-overlay.modal-overlay--centered [data-testid='quick-issue-dialog']")
  end

  def expect_inside_viewport
    panel = rect(panel_selector)
    vp    = viewport
    expect(panel["top"]).to be >= 0
    expect(panel["bottom"]).to be <= vp["height"]
    expect(panel["left"]).to be >= 0
    expect(panel["right"]).to be <= vp["width"]
    panel
  end

  def expect_header_and_actions_visible
    page.execute_script("document.querySelector(#{panel_selector.to_json}).scrollTop = 100000")
    panel   = rect(panel_selector)
    header  = rect(".qi__header")
    actions = rect(".qi__actions")
    expect(header["top"]).to be >= panel["top"] - 1
    expect(actions["bottom"]).to be <= panel["bottom"] + 1
    expect(actions["top"]).to be >= panel["top"]
  end

  shared_examples "the centered Stock Issue modal" do
    it "opens for the row's product, centered on desktop, with no way to change the product" do
      set_viewport(1280, 900)
      open_from_row

      expect(find("[data-testid='quick-issue-product']")).to have_text("Shampoo")
      expect(page).to have_no_css("[data-testid='quick-issue-change-product']")
      expect(page).to have_no_css("#modal-overlay select[name='product_id']")

      panel = expect_inside_viewport
      vp    = viewport
      expect((panel["top"] - (vp["height"] - panel["bottom"])).abs).to be <= 2 # vertically centered
      expect((panel["left"] - (vp["width"] - panel["right"])).abs).to be <= 2  # horizontally centered
    end

    it "fits a narrow viewport, scrolling its body while the header and actions stay reachable" do
      set_viewport(390, 560)
      open_from_row
      expect_inside_viewport
      expect_header_and_actions_visible
    end

    it "requires Notes only for Other" do
      set_viewport(1280, 900)
      open_from_row
      notes = find("textarea[name='quick_issue[notes]']")
      reason = find("select[name='quick_issue[issue_reason]']")
      expect(notes[:required]).to be_in([ nil, "false", false ])

      reason.find("option[value='other']").select_option
      expect(page).to have_css("label.form-label--required[for='#{notes[:id]}']")
      expect(page.evaluate_script("document.querySelector(\"textarea[name='quick_issue[notes]']\").required")).to be(true)
      expect(find("[data-testid='quick-issue-notes-hint']")).to have_text(I18n.t("inventory.quick_issue.notes_other_hint", locale: locale))

      reason.find("option[value='damaged']").select_option
      expect(page.evaluate_script("document.querySelector(\"textarea[name='quick_issue[notes]']\").required")).to be(false)
      expect(find("[data-testid='quick-issue-notes-hint']")).to have_text(I18n.t("inventory.quick_issue.notes_hint", locale: locale))
    end

    it "drops the centered placement when closed" do
      set_viewport(1280, 900)
      open_from_row
      find("[data-testid='quick-issue-cancel']").click
      expect(page).to have_no_css("#modal-overlay.modal-overlay--centered")
      expect(page).to have_no_css("[data-testid='quick-issue-dialog']")
      expect(page.evaluate_script("document.documentElement.classList.contains('modal-open')")).to be(false)

      # Any other modal content afterwards keeps the default bottom-sheet placement.
      page.execute_script("document.getElementById('modal').innerHTML = '<div data-testid=\"other-modal\">x</div>'")
      expect(page).to have_css("[data-testid='other-modal']")
      expect(page).to have_no_css("#modal-overlay.modal-overlay--centered")
      # The layout's bottom sheet (inline flex-end; Chrome reports it as "flow-end"), not centered.
      expect(page.evaluate_script("getComputedStyle(document.getElementById('modal-overlay')).alignItems")).to be_in(%w[flex-end flow-end end])
    end

    it "posts the issue from the popup and leaves it" do
      set_viewport(1280, 900)
      open_from_row
      fill_in "quick_issue[quantity]", with: "2"
      find("select[name='quick_issue[issue_reason]']").find("option[value='damaged']").select_option
      find("[data-testid='quick-issue-submit']").click

      expect(page).to have_no_css("[data-testid='quick-issue-dialog']")
      expect(page).to have_current_path(%r{/inventory/stock_issues/\d+})
      expect(StockIssue.order(:id).last).to have_attributes(status: "issued", workflow: "quick_issue", warehouse_id: warehouse.id)
    end
  end

  context "in English (LTR)" do
    let(:locale) { "en" }

    it_behaves_like "the centered Stock Issue modal"
  end

  context "in Arabic (RTL)" do
    let(:locale) { "ar" }

    it_behaves_like "the centered Stock Issue modal"

    it "is titled صرف مخزني and laid out right-to-left" do
      set_viewport(1280, 900)
      open_from_row
      expect(find("#quick-issue-title")).to have_text("صرف مخزني")
      expect(page.evaluate_script("document.documentElement.dir")).to eq("rtl")
    end
  end

  it "leaves the Products header and the workspace navigation without a Stock Issue link" do
    visit inventory_products_path
    expect(page).to have_no_css("[data-testid='products-quick-issue']")
    expect(page).to have_no_css(".ws__rail a[href^='#{new_inventory_quick_issue_path}'], .ws__tabs a[href^='#{new_inventory_quick_issue_path}']")
  end
end
