require "rails_helper"

# Browser coverage (Arabic): the goods receipt Show page has ONE workflow action
# area, directly under the receipt number and status, offering exactly what
# GoodsReceiptPolicy allows; it stays usable and overflow-free on phones.
#
# Set SCREENSHOT_DIR=/some/dir to also save screenshots.
RSpec.describe "Goods receipt show — top action bar (browser, Arabic)", type: :system do
  let(:business)  { create(:business) }
  let(:admin)     { create(:user, :super_admin, business: business, preferred_locale: "ar") }
  let(:warehouse) { business.warehouses.create!(name: "المستودع الرئيسي") }
  let(:product) do
    business.products.create!(name: "صبغة شعر احترافية طويلة الاسم", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0)
  end

  def user_with(*perms)
    role = create(:permission_role, business: business, permissions: perms.map(&:to_s))
    create(:user, business: business, permission_role: role, preferred_locale: "ar")
  end

  def build_receipt
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current,
                                      funding_source_kind: "supplier_credit", notes: "ملاحظة طويلة " * 12)
    r.items.build(product: product, quantity: 5, unit_cost: 1_250.75)
    r.save!
    r.update_column(:approval_status, "pending_approval")
    r.reload
  end

  def approval(receipt) = Inventory::GoodsReceiptApproval.new(goods_receipt_id: receipt.id, actor: admin)
  def approved = build_receipt.tap { |r| approval(r).approve! }.reload
  def gr(key) = I18n.t("inventory.goods_receipts.#{key}", locale: :ar)

  def set_viewport(width, height = 800)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: width, height: height, deviceScaleFactor: 1, mobile: width < 768)
  end

  def rect(selector)
    page.evaluate_script(<<~JS)
      (() => { const r = document.querySelector(#{selector.to_json}).getBoundingClientRect();
               return { top: r.top, bottom: r.bottom, left: r.left, right: r.right, width: r.width, height: r.height }; })()
    JS
  end

  def expect_no_horizontal_overflow
    expect(page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")).to be <= 0
  end

  def screenshot(name)
    dir = ENV["SCREENSHOT_DIR"]
    page.save_screenshot(File.join(dir, "#{name}.png")) if dir.present?
  end

  def bar = find("[data-testid='gr-actions']")
  def approve_forms(receipt) = all("form[action='#{approve_inventory_goods_receipt_path(receipt)}']", visible: :all)
  def reject_forms(receipt)  = all("form[action='#{reject_inventory_goods_receipt_path(receipt)}']", visible: :all)
  def confirm_forms(receipt) = all("form[action='#{confirm_inventory_goods_receipt_path(receipt)}']", visible: :all)

  describe "pending approval" do
    it "shows اعتماد and رفض at the top — once — above the status summary, and approval works" do
      receipt = build_receipt
      sign_in admin
      visit inventory_goods_receipt_path(receipt)

      within(".record-header") do
        expect(page).to have_css("h1", text: receipt.receipt_number)
        expect(page).to have_css("[data-testid='gr-header-approval']", text: gr("approval_statuses.pending_approval"))
        within(bar) do
          expect(page).to have_button(gr("approve"))
          expect(page).to have_button(gr("reject"))
        end
      end
      expect(approve_forms(receipt).size).to eq(1)
      expect(reject_forms(receipt).size).to eq(1)
      expect(rect("[data-testid='gr-actions']")["bottom"]).to be < rect(".record-header + .card, .record-header ~ .card")["top"]

      dismiss_confirm(gr("approve_hint")) { within(bar) { click_button gr("approve") } }
      expect(receipt.reload.approval_status).to eq("pending_approval")

      accept_confirm(gr("approve_hint")) { within(bar) { click_button gr("approve") } }
      expect(page).to have_text(gr("approved"))
      expect(receipt.reload.approval_status).to eq("approved")
    end

    it "rejects from the top bar with a required reason" do
      receipt = build_receipt
      sign_in admin
      visit inventory_goods_receipt_path(receipt)

      expect(page).to have_no_css("dialog#reject-dialog[open]")
      within(bar) { click_button gr("reject") }
      within("dialog#reject-dialog[open]") do
        expect(find("#reject-dialog-reason")[:required]).to be_truthy
        fill_in "reject-dialog-reason", with: "سعر خاطئ"
        accept_confirm(gr("reject_confirm")) { click_button gr("reject_submit") }
      end

      expect(page).to have_text(gr("rejected"))
      expect(receipt.reload).to have_attributes(approval_status: "rejected", rejection_reason: "سعر خاطئ")
    end

    it "shows no Approve/Reject to a user without approval permission" do
      receipt = build_receipt
      sign_in user_with(:view_inventory)
      visit inventory_goods_receipt_path(receipt)

      expect(page).to have_css("h1", text: receipt.receipt_number)
      within(bar) do
        expect(page).to have_no_button(gr("approve"))
        expect(page).to have_no_button(gr("reject"))
        expect(page).to have_link(I18n.t("forms.back", locale: :ar))
      end
      expect(approve_forms(receipt)).to be_empty
      expect(reject_forms(receipt)).to be_empty
    end
  end

  describe "approved, not received" do
    it "offers تأكيد الإذن at the top, and it works" do
      receipt = approved
      sign_in admin
      visit inventory_goods_receipt_path(receipt)

      within(bar) do
        expect(page).to have_no_button(gr("approve"))
        expect(page).to have_no_button(gr("reject"))
        accept_confirm(gr("confirm_hint")) { click_button gr("confirm") }
      end
      expect(page).to have_text(gr("confirmed"))
      expect(receipt.reload).to be_confirmed
    end
  end

  describe "states with no workflow step left" do
    it "fully received: no receiving or approval action" do
      receipt = approved.tap do |r|
        Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: r.id, actor: admin).call
      end
      sign_in admin
      visit inventory_goods_receipt_path(receipt)

      expect(confirm_forms(receipt)).to be_empty
      expect(approve_forms(receipt)).to be_empty
      expect(reject_forms(receipt)).to be_empty
    end

    it "cancelled: no actions at all" do
      receipt = build_receipt.tap do |r|
        Inventory::GoodsReceiptVoider.new(goods_receipt_id: r.id, actor: admin, reason: "مكرر").call
      end
      sign_in admin
      visit inventory_goods_receipt_path(receipt)

      expect(page).to have_css("[data-testid='gr-header-approval']", text: gr("approval_statuses.cancelled"))
      expect(bar.all("button")).to be_empty # only رجوع remains
      expect(bar).to have_link(I18n.t("forms.back", locale: :ar))
      expect(page).to have_text(I18n.t("inventory.void.void_reason", locale: :ar))
    end

    it "rejected: no approve / reject / receive (resubmitting stays available)" do
      receipt = build_receipt.tap { |r| approval(r).reject!(reason: "سعر خاطئ") }
      sign_in admin
      visit inventory_goods_receipt_path(receipt)

      expect(approve_forms(receipt)).to be_empty
      expect(reject_forms(receipt)).to be_empty
      expect(confirm_forms(receipt)).to be_empty
      within(bar) { expect(page).to have_button(gr("submit_for_approval")) }
    end
  end

  describe "mobile (375px)" do
    before { set_viewport(375) }

    it "keeps the header and actions in the first screen, tappable, with stacked cards and no overflow" do
      receipt = build_receipt
      sign_in admin
      visit inventory_goods_receipt_path(receipt)
      screenshot("gr_show_mobile_top")

      expect_no_horizontal_overflow
      bar_box = rect("[data-testid='gr-actions']")
      expect(bar_box["bottom"]).to be <= 800

      %w[gr-approve gr-reject].each do |id|
        box = rect("button[data-testid='#{id}'], [data-testid='#{id}'] > button")
        expect(box["height"]).to be >= 44
        expect(box["width"]).to be >= 120
      end

      # Main information cards are full width and stacked.
      widths = page.evaluate_script(<<~JS)
        Array.from(document.querySelectorAll(".admin-page > .card")).map(c => c.getBoundingClientRect().width)
      JS
      page_width = page.evaluate_script("document.querySelector('.admin-page').clientWidth")
      expect(widths).not_to be_empty
      widths.each { |w| expect(w).to be_within(40).of(page_width) }

      within(bar) { click_button gr("reject") }
      expect_no_horizontal_overflow
      screenshot("gr_show_mobile_reject_open")
      expect(rect("#reject-dialog button[type='submit']")["height"]).to be >= 44
      expect(rect("#reject-dialog")["width"]).to be <= 375

      page.execute_script("window.scrollTo(0, document.body.scrollHeight)")
      screenshot("gr_show_mobile_bottom")
      expect_no_horizontal_overflow
    end

    it "the approve button works on a phone" do
      receipt = build_receipt
      sign_in admin
      visit inventory_goods_receipt_path(receipt)

      accept_confirm(gr("approve_hint")) { within(bar) { click_button gr("approve") } }
      expect(page).to have_text(gr("approved"))
      expect(receipt.reload.approval_status).to eq("approved")
    end
  end
end
