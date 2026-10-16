require "rails_helper"

# Browser coverage (Arabic RTL): approve, reject and receive a Goods Receipt
# straight from its Purchase Request's "أذونات الاستلام" table — staying on the
# Purchase Request — at desktop and phone widths, without horizontal scroll.
#
# Set SCREENSHOT_DIR=/some/dir to also save screenshots.
RSpec.describe "Purchase Request page — goods receipt actions (browser)", type: :system do
  let(:business)  { create(:business) }
  let(:admin)     { create(:user, :super_admin, business: business, preferred_locale: "ar") }
  let(:supplier)  { business.suppliers.create!(name: "مورد مستحضرات") }
  let(:warehouse) { business.warehouses.create!(name: "المستودع الرئيسي") }
  let!(:shampoo)  { business.products.create!(name: "شامبو", sku: "SH-1", average_cost_price: 10) }

  let!(:pr) do
    request = business.purchase_requests.build(supplier: supplier, source: "low_stock_alert", created_by: admin)
    request.items.build(product: shampoo, quantity: 10, unit_price: 20, source_warehouse: warehouse)
    request.save!
    request.update_columns(status: "pending_approval", submitted_by_id: admin.id)
    Inventory::PurchaseRequestApproval.new(purchase_request_id: request.id, actor: admin).approve!
    request.reload
  end

  def receipt(quantity, funding: "supplier_credit", account: nil)
    r = business.goods_receipts.build(purchase_request: pr, supplier: supplier, warehouse: warehouse,
                                      received_on: Date.current, funding_source_kind: funding, funding_source: account)
    r.items.build(product: shampoo, quantity: quantity, unit_cost: 20, purchase_request_item: pr.items.first)
    r.save!
    r.update_column(:approval_status, "pending_approval")
    r.reload
  end

  def gr(key) = I18n.t("inventory.goods_receipts.#{key}", locale: :ar)

  def set_viewport(width, height = 1600)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: width, height: height, deviceScaleFactor: 1, mobile: width < 768)
  end

  def row(receipt) = find("#goods-receipts tbody tr", text: receipt.receipt_number)
  def on_purchase_request = expect(page).to(have_current_path(inventory_purchase_request_path(pr)))

  def expect_no_overflow
    expect(page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")).to be <= 0
  end

  def screenshot(name)
    dir = ENV["SCREENSHOT_DIR"]
    page.save_screenshot(File.join(dir, "#{name}.png")) if dir.present?
  end

  before { sign_in admin }

  [ 1280, 390 ].each do |width|
    context "at #{width}px" do
      before { set_viewport(width) }

      it "approves, then receives, a goods receipt without leaving the Purchase Request" do
        r = receipt(4)
        visit inventory_purchase_request_path(pr)
        expect(page).to have_css("html[dir='rtl']")
        expect_no_overflow
        row(r).scroll_to(:center)
        screenshot("pr_gr_actions_#{width}")

        within(row(r)) do
          expect(page).to have_button(gr("approve"))
          expect(page).to have_button(gr("reject"))
          expect(page).to have_link(gr("view_action"))
          accept_confirm(gr("approve_hint")) { click_button gr("approve") }
        end
        expect(page).to have_text(gr("approved"))
        on_purchase_request
        expect(r.reload.approval_status).to eq("approved")

        within(row(r)) do
          expect(page).to have_css(".badge", text: gr("approval_statuses.approved"))
          expect(page).to have_no_button(gr("approve"))
          accept_confirm(gr("confirm_hint")) { click_button gr("confirm") }
        end
        expect(page).to have_text(gr("confirmed"))
        on_purchase_request
        expect(r.reload).to be_confirmed
        expect(shampoo.reload.current_stock).to eq(4)
        within(row(r)) do
          expect(page).to have_no_button(gr("confirm"))
          expect(page).to have_link(gr("view_action"))
        end
        expect_no_overflow
      end

      it "rejects with the existing reason dialog without leaving the Purchase Request" do
        r = receipt(3)
        visit inventory_purchase_request_path(pr)

        within(row(r)) { click_button gr("reject") }
        within("dialog#reject-dialog-#{r.id}[open]") do
          expect_no_overflow
          fill_in "reject-dialog-#{r.id}-reason", with: "سعر خاطئ"
          accept_confirm(gr("reject_confirm")) { click_button gr("reject_submit") }
        end

        expect(page).to have_text(gr("rejected"))
        on_purchase_request
        expect(r.reload).to have_attributes(approval_status: "rejected", rejection_reason: "سعر خاطئ")
        within(row(r)) { expect(page).to have_no_button(gr("approve")) }
      end
    end
  end

  it "phone: actions are tappable (≥44px) and sit inside the receipt card" do
    r = receipt(2)
    set_viewport(390)
    visit inventory_purchase_request_path(pr)

    boxes = page.evaluate_script(<<~JS)
      (() => { const tr = Array.from(document.querySelectorAll('#goods-receipts tbody tr')).find(t => t.textContent.includes(#{r.receipt_number.to_json}));
               const c = tr.getBoundingClientRect();
               return Array.from(tr.querySelectorAll('.action-group > .btn, .action-group__item > .btn')).map(b => {
                 const x = b.getBoundingClientRect(); return { h: x.height, inside: x.left >= c.left - 1 && x.right <= c.right + 1 }; }); })()
    JS
    expect(boxes.size).to eq(3) # اعتماد · رفض · عرض
    boxes.each do |b|
      expect(b["h"]).to be >= 44
      expect(b["inside"]).to be(true)
    end
  end

  it "a custody-funded receipt shows the custody balance preview in a dialog and approves in place" do
    account = create(:custody_account, business: business, user: admin, name: "عهدة المشتريات")
    account.custody_transactions.create!(business: business, txn_type: "top_up", amount: 500)
    account.refresh_balance!
    r = receipt(5, funding: "employee_custody", account: account)

    set_viewport(390)
    visit inventory_purchase_request_path(pr)
    within(row(r)) { click_button gr("approve") }
    within("dialog#approve-dialog-#{r.id}[open]") do
      expect(page).to have_css("[data-testid='custody-preview-due']", text: "100")
      expect(page).to have_css("[data-testid='custody-preview-after']", text: "400")
      screenshot("pr_gr_custody_dialog_390")
      accept_confirm(gr("approve_hint")) { click_button gr("approve") }
    end

    expect(page).to have_text(gr("approved"))
    on_purchase_request
    expect(r.reload.approval_status).to eq("approved")
    expect(Finance::CustodyBalance.new(account).current).to eq(400)
  end
end
