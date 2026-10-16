require "rails_helper"

# Browser coverage (Arabic): Goods Receipts index row actions are visible and
# usable on phone and desktop widths, keep the Show page's confirmations, and
# never push the page into horizontal scroll.
#
# Set SCREENSHOT_DIR=/some/dir to also save a screenshot per width.
RSpec.describe "Goods receipts index — row actions (browser, Arabic)", type: :system do
  let(:business)  { create(:business) }
  let(:admin)     { create(:user, :super_admin, business: business, preferred_locale: "ar") }
  let(:warehouse) { business.warehouses.create!(name: "المستودع الرئيسي") }
  let(:supplier)  { business.suppliers.create!(name: "مؤسسة التوريدات الحديثة للتجارة") }
  let(:product) do
    business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0)
  end

  def build_receipt
    r = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current,
                                      funding_source_kind: "supplier_credit")
    r.items.build(product: product, quantity: 5, unit_cost: 10)
    r.save!
    r.update_column(:approval_status, "pending_approval")
    r.reload
  end

  def set_viewport(width, height = 900)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: width, height: height, deviceScaleFactor: 1, mobile: width < 768)
  end

  def row(receipt) = find("tbody tr", text: receipt.receipt_number)
  def gr(key) = I18n.t("inventory.goods_receipts.#{key}", locale: :ar)

  def expect_no_horizontal_overflow
    overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
    expect(overflow).to be <= 0
  end

  def screenshot(name)
    dir = ENV["SCREENSHOT_DIR"]
    page.save_screenshot(File.join(dir, "#{name}.png")) if dir.present?
  end

  before { sign_in admin }

  [ 375, 1280 ].each do |width|
    context "at #{width}px" do
      before { set_viewport(width) }

      it "approves from the index after the Show page's confirmation, then offers تأكيد الإذن" do
        receipt = build_receipt
        visit inventory_goods_receipts_path
        expect_no_horizontal_overflow
        row(receipt).scroll_to(:center)
        screenshot("gr_index_actions_#{width}")

        within(row(receipt)) do
          expect(page).to have_link(gr("view_action"))
          dismiss_confirm(gr("approve_hint")) { click_button gr("approve") }
        end
        expect(receipt.reload.approval_status).to eq("pending_approval")

        within(row(receipt)) { accept_confirm(gr("approve_hint")) { click_button gr("approve") } }
        expect(page).to have_current_path(inventory_goods_receipts_path)
        expect(page).to have_text(gr("approved"))
        expect(receipt.reload.approval_status).to eq("approved")

        within(row(receipt)) do
          expect(page).to have_no_button(gr("approve"))
          accept_confirm(gr("confirm_hint")) { click_button gr("confirm") }
        end
        expect(page).to have_text(gr("confirmed"))
        expect(receipt.reload).to be_confirmed
        within(row(receipt)) do
          expect(page).to have_no_button(gr("confirm"))
          expect(page).to have_link(gr("view_action"))
        end
      end

      it "rejects from the index with a required reason, without overflowing the page" do
        receipt = build_receipt
        visit inventory_goods_receipts_path

        within(row(receipt)) do
          click_button gr("reject")
          expect_no_horizontal_overflow
          current_scope.scroll_to(:center)
          screenshot("gr_index_reject_open_#{width}")
          fill_in "reject-dialog-#{receipt.id}-reason", with: "سعر خاطئ"
          accept_confirm(gr("reject_confirm")) { click_button gr("reject_submit") }
        end

        expect(page).to have_text(gr("rejected"))
        expect(receipt.reload).to have_attributes(approval_status: "rejected", rejection_reason: "سعر خاطئ")
        within(row(receipt)) do
          expect(page).to have_no_button(gr("approve"))
          expect(page).to have_no_button(gr("reject"))
        end
      end
    end
  end

  [ 1280, 1024 ].each do |width|
    it "desktop #{width}px: actions sit on one line, centred, without growing the row, overlapping or clipping" do
      pending_receipt = build_receipt
      received = build_receipt.tap do |r|
        Inventory::GoodsReceiptApproval.new(goods_receipt_id: r.id, actor: admin).approve!
        Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: r.id, actor: admin).call
      end
      set_viewport(width)
      visit inventory_goods_receipts_path

      box = ->(js) { page.evaluate_script(js) }
      geometry = lambda do |receipt|
        box.call(<<~JS)
          (() => {
            const tr = Array.from(document.querySelectorAll("tbody tr")).find(r => r.textContent.includes(#{receipt.receipt_number.to_json}));
            const cell = tr.querySelector("td.col-actions"), total = cell.previousElementSibling;
            const btns = Array.from(cell.querySelectorAll(".action-group > .btn, .action-group__item > .btn")).map(b => b.getBoundingClientRect());
            const c = cell.getBoundingClientRect(), t = total.getBoundingClientRect();
            return { row: tr.getBoundingClientRect().height, tops: btns.map(b => Math.round(b.top)),
                     heights: btns.map(b => Math.round(b.height)), cellMid: c.top + c.height / 2,
                     btnMid: btns[0].top + btns[0].height / 2, overlap: Math.max(0, Math.min(c.right, t.right) - Math.max(c.left, t.left)) };
          })()
        JS
      end

      pending = geometry.call(pending_receipt)
      plain   = geometry.call(received)

      expect(pending["tops"].size).to eq(3)                    # اعتماد · رفض · عرض
      expect(pending["tops"].uniq.size).to eq(1)               # one line
      expect(pending["heights"].uniq.size).to eq(1)            # equal heights
      expect(pending["row"]).to be_within(4).of(plain["row"])  # no taller than a عرض-only row
      expect(pending["btnMid"]).to be_within(2).of(pending["cellMid"])
      expect(pending["overlap"]).to eq(0)
      expect_no_horizontal_overflow
      # The whole table fits: nothing is clipped behind the table's own scroll.
      expect(box.call("(w => w.scrollWidth - w.clientWidth)(document.querySelector('.table-wrap'))")).to be <= 0
    end
  end

  it "opens the receipt from عرض" do
    receipt = build_receipt
    set_viewport(375)
    visit inventory_goods_receipts_path
    within(row(receipt)) { click_link gr("view_action") }
    expect(page).to have_current_path(inventory_goods_receipt_path(receipt))
  end
end
