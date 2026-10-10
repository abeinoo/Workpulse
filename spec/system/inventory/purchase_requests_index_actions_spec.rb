require "rails_helper"

# Browser coverage: the Purchase Requests list has ONE actions area per row —
# the request's next step as the primary action, عرض, and ⋮ for the rest —
# with approval status and receiving progress shown separately. Table where
# the list has room (Arabic from ~920px of list, e.g. 1440px screens), cards
# below that and on phones; never horizontal scroll.
#
# Set SCREENSHOT_DIR=/some/dir to also save screenshots.
RSpec.describe "Purchase Requests index — actions and layout (browser)", type: :system do
  let(:business)  { create(:business, currency: "EGP") }
  let(:owner)     { create(:user, :super_admin, business: business, preferred_locale: "ar", first_name: "أحمد", last_name: "بهاء") }
  let(:submitter) { create(:user, business: business) }
  let(:supplier)  { business.suppliers.create!(name: "بداية للكلمات - قصر العيني للتجارة") }
  let(:warehouse) { business.warehouses.create!(name: "المستودع الرئيسي") }
  let!(:product)  { business.products.create!(name: "شامبو", sku: "SH-1", average_cost_price: 50) }

  def request_with(status, quantity: 24)
    pr = business.purchase_requests.build(supplier: supplier, source: "low_stock_alert", created_by: owner)
    pr.items.build(product: product, quantity: quantity, unit_price: 56, source_warehouse: warehouse)
    pr.save!
    pr.update_columns(status: status, submitted_by_id: submitter.id) unless status == "draft"
    pr.reload
  end

  let!(:pending)        { request_with("pending_approval") }
  let!(:approved)       { request_with("approved") }
  let!(:fully_received) { request_with("fully_received") }
  let!(:rejected)       { request_with("rejected") }

  def pr_t(key) = I18n.t("inventory.purchase_requests.#{key}", locale: :ar)
  def row(pr) = find(".pr-list__row", text: pr.request_number)

  def set_viewport(width, height = 1400)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: width, height: height, deviceScaleFactor: 1, mobile: width < 768)
  end

  def js(script) = page.evaluate_script(script)

  def expect_no_overflow
    expect(js("document.documentElement.scrollWidth - document.documentElement.clientWidth")).to be <= 0
    expect(js("(w => w.scrollWidth - w.clientWidth)(document.querySelector('.pr-list__table'))")).to be <= 1
  end

  def card_mode? = js("getComputedStyle(document.querySelector('.pr-list__row')).display") == "grid"

  def screenshot(name)
    dir = ENV["SCREENSHOT_DIR"]
    page.save_screenshot(File.join(dir, "#{name}.png")) if dir.present?
  end

  def button_boxes(pr)
    js(<<~JS)
      (() => { const tr = Array.from(document.querySelectorAll('.pr-list__row')).find(r => r.textContent.includes(#{pr.request_number.to_json}));
               return Array.from(tr.querySelectorAll('.pr-actions > .btn, .pr-actions > .action-group__item > .btn, .pr-actions .pr-actions__more'))
                 .map(b => { const x = b.getBoundingClientRect(); return { top: Math.round(x.top), h: Math.round(x.height), w: Math.round(x.width) }; }); })()
    JS
  end

  before { sign_in owner }

  describe "Arabic desktop (1440px): table" do
    before do
      set_viewport(1440)
      visit inventory_purchase_requests_path
    end

    it "shows one actions column, the next step once, compact rows, and no overflow" do
      expect(card_mode?).to be(false)
      %w[items total receiving].each do |cell|
        expect(row(approved).find("td.pr-list__#{cell}").evaluate_script("getComputedStyle(this).display")).to eq("table-cell")
      end
      expect_no_overflow
      expect(all(".pr-list thead th").map { |th| th.text.strip }).not_to include(pr_t("next_action_column"))
      screenshot("pr_index_1440")

      within(row(approved)) do
        expect(page).to have_link(pr_t("actions.create_goods_receipt"), count: 1)
        expect(page).to have_link(pr_t("view"))
        expect(page).to have_css(".pr-progress", text: pr_t("receiving_statuses.not_started"))
        expect(page).to have_text("0 / 24")
      end
      within(row(fully_received)) do
        expect(page).to have_no_link(pr_t("actions.create_goods_receipt"))
        expect(page).to have_text(pr_t("all_received"))
        expect(page).to have_css(".pr-list__status", text: pr_t("statuses.approved"))
      end
      within(row(rejected)) { expect(page).to have_no_css("form") }

      # Pending: اعتماد · رفض · عرض on ONE line; the row is no taller than a عرض-only row.
      boxes = button_boxes(pending)
      expect(boxes.map { |b| b["top"] }.uniq.size).to eq(1)
      pending_h  = row(pending).evaluate_script("this.getBoundingClientRect().height")
      rejected_h = row(rejected).evaluate_script("this.getBoundingClientRect().height")
      expect(pending_h).to be_within(6).of(rejected_h)
    end

    it "approves a pending request through the existing endpoint (which opens the request, as before)" do
      within(row(pending)) { click_button pr_t("actions.approve") }
      expect(page).to have_text(pr_t("approved"))
      expect(page).to have_current_path(inventory_purchase_request_path(pending))
      expect(pending.reload).to be_approved

      visit inventory_purchase_requests_path
      within(row(pending)) { expect(page).to have_link(pr_t("actions.create_goods_receipt")) }
    end

    it "rejects through the reason dialog" do
      within(row(pending)) { click_button pr_t("actions.reject") }
      within("dialog#pr-reject-dialog-#{pending.id}[open]") do
        fill_in "pr-reject-dialog-#{pending.id}-reason", with: "السعر مرتفع"
        click_button pr_t("actions.reject")
      end
      expect(page).to have_text(pr_t("rejected"))
      expect(pending.reload).to be_rejected
      expect(pending.rejection_reason).to eq("السعر مرتفع")
    end

    it "opens the ⋮ menu with the remaining actions" do
      within(row(approved)) do
        find("[data-testid='pr-more']").click
        expect(page).to have_css("[role='menu']:not([hidden])")
        expect(page).to have_link("#{pr_t('actions.cancel')}…")
      end
    end

    it "bulk bar: counts the selection, explains what can be selected, and only pending rows are selectable" do
      expect(row(approved).find(".pr-bulk-check-row", visible: :all)).to be_disabled
      row(pending).find(".pr-bulk-check-row").check
      within(".bulk-action-bar") do
        expect(page).to have_text(/#{pr_t('bulk.selected_count')}\s*1/)
        expect(page).to have_css("[data-testid='pr-bulk-hint']", text: pr_t("bulk.only_pending_hint"))
        expect(page).to have_button(pr_t("bulk.approve"))
      end
    end
  end

  describe "phone (390px): cards" do
    it "shows readable cards with a full-width, tappable primary action and no horizontal scroll" do
      set_viewport(390, 2400)
      visit inventory_purchase_requests_path

      expect(card_mode?).to be(true)
      expect_no_overflow
      screenshot("pr_index_390")

      boxes = button_boxes(approved)
      card_w = row(approved).evaluate_script("this.getBoundingClientRect().width")
      primary = boxes.first
      expect(primary["h"]).to be >= 44
      expect(primary["w"]).to be > card_w * 0.8
      boxes.each { |b| expect(b["h"]).to be >= 44 }

      within(row(approved)) { click_link pr_t("actions.create_goods_receipt") }
      expect(page).to have_current_path(new_inventory_goods_receipt_path(purchase_request_id: approved.id))
    end
  end

  describe "English desktop (1440px)" do
    it "uses cards (the English table needs more width than the page gives it) without overflow" do
      owner.update!(preferred_locale: "en")
      set_viewport(1440)
      visit inventory_purchase_requests_path
      expect(page).to have_css("html[dir='ltr']")
      expect(card_mode?).to be(true)
      expect_no_overflow
    end
  end
end
