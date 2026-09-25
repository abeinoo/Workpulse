require "rails_helper"

RSpec.describe "Goods receipt financial settlement (browser)", type: :system do
  let(:business)  { create(:business) }
  let(:admin)     { create(:user, :super_admin, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:supplier)  { business.suppliers.create!(name: "Acme Supplies") }
  let(:product) do
    business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0)
  end
  # Employee Custody is always the logged-in user's own account.
  let!(:account) { create(:custody_account, business: business, user: admin, name: "Admin Float") }
  let!(:receipt) do
    r = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current,
                                      funding_source_kind: "supplier_credit")
    r.items.build(product: product, quantity: 100, unit_cost: 50)
    r.save!
    r.update_column(:approval_status, "pending_approval")
    Inventory::GoodsReceiptApproval.new(goods_receipt_id: r.id, actor: admin).approve!
    r.reload
  end

  before do
    account.custody_transactions.create!(business: business, txn_type: "top_up", amount: 7_000)
    account.refresh_balance!
  end

  # Opt-in visual check: SETTLEMENT_SCREENSHOT_DIR=... saves captures. `tall`
  # grows the window to capture the whole page — only used as a test's last step.
  def screenshot(name, tall: false)
    dir = ENV["SETTLEMENT_SCREENSHOT_DIR"]
    return if dir.blank?

    if tall
      width = page.evaluate_script("window.innerWidth")
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                      width: width, height: 3200, deviceScaleFactor: 1, mobile: width < 768)
    end
    page.save_screenshot(File.join(dir, "#{name}.png"))
  end

  # Test-only stabilization (production CSS untouched). The app sets
  # `html { scroll-behavior: smooth }`, so after a Turbo redirect the page
  # animates back to the top; Selenium could compute a button's position and
  # click mid-animation, missing it (seen as the next page's field "not found").
  # Also waits for any finite CSS animation in flight (e.g. the PWA banner
  # sliding in) and for scrolling to come to rest — event-driven via
  # Animation#finished and requestAnimationFrame, no sleeps. Infinite
  # animations (spinners, pulses) are ignored so this can never hang.
  def stabilize_page!
    page.execute_script("document.documentElement.style.scrollBehavior = 'auto'")
    page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      const finite = document.getAnimations().filter(a => a.effect && a.effect.getComputedTiming().endTime !== Infinity);
      // A smooth scroll already in flight isn't a Web Animation: also wait
      // until the scroll position is unchanged across consecutive frames.
      const scrollSettled = () => new Promise(resolve => {
        let last = window.scrollY, still = 0;
        const tick = () => {
          still = window.scrollY === last ? still + 1 : 0;
          last = window.scrollY;
          still >= 3 ? resolve() : requestAnimationFrame(tick);
        };
        requestAnimationFrame(tick);
      });
      Promise.all(finite.map(a => a.finished.catch(() => null))).then(scrollSettled).then(() => done(true));
    JS
  end

  def no_horizontal_scroll?
    page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth + 1")
  end

  def settlement_t(key, **) = I18n.t("inventory.goods_receipts.settlements.#{key}", **)

  # Badges are uppercased by CSS, so match status labels case-insensitively.
  def status_text(key) = /#{Regexp.escape(I18n.t("inventory.goods_receipts.financial_statuses.#{key}"))}/i

  it "desktop / English: settle partially from my own custody, then from company cash, then reverse" do
    sign_in admin
    visit inventory_goods_receipt_path(receipt)
    expect(page).to have_content(status_text("pending_settlement"))
    stabilize_page!

    first(:link, settlement_t("action")).click
    expect(page).to have_content(settlement_t("new_title"))
    stabilize_page!

    # No employee picker at all; choosing Employee Custody shows MY balance.
    choose "settlement_source_kind_employee_custody"
    expect(page).to have_no_css("select")
    expect(page).to have_css("[data-settlement-form-target='available']", text: "SAR 7,000.00")
    fill_in "settlement_amount", with: "2000"
    screenshot("desktop_en_form")
    accept_confirm { click_button settlement_t("submit") }

    expect(page).to have_content(settlement_t("recorded"))
    expect(page).to have_content(status_text("partially_settled"))
    expect(account.reload.current_balance).to eq(5_000)
    stabilize_page!

    first(:link, settlement_t("action")).click
    expect(page).to have_content(settlement_t("new_title"))
    stabilize_page!
    choose "settlement_source_kind_company_cash"
    fill_in "settlement_amount", with: "3000"
    fill_in "settlement_reference", with: "CV-9"
    accept_confirm { click_button settlement_t("submit") }

    expect(page).to have_content(status_text("settled"))
    expect(page).not_to have_link(settlement_t("action"))
    expect(page).to have_content("CV-9")
    stabilize_page!
    screenshot("desktop_en_settled")

    first_settlement = receipt.financial_settlements.order(:id).first
    within("#settlement-#{first_settlement.id}") do
      find("summary", text: settlement_t("reverse_action")).click
      fill_in "reversal_reason_#{first_settlement.id}", with: "Wrong employee"
      accept_confirm { click_button settlement_t("reverse_submit") }
    end

    expect(page).to have_content(settlement_t("reversed"))
    expect(page).to have_content(/#{settlement_t("statuses.reversed")}/i)
    expect(page).to have_content("Wrong employee")
    expect(page).to have_content(status_text("partially_settled"))
    expect(account.reload.current_balance).to eq(7_000)
    expect(no_horizontal_scroll?).to be true
    screenshot("desktop_en_reversed", tall: true)
  end

  it "mobile / Arabic RTL: form and history render without horizontal scrolling" do
    admin.update!(preferred_locale: "ar")
    Inventory::GoodsReceiptSettlementRecorder.new(receipt.id, actor: admin, params: {
      source_kind: "employee_custody", amount: "2000", reference: "TRX-1"
    }).call
    # Device emulation: headless Chrome won't shrink a real window below ~500px.
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    sign_in admin

    visit inventory_goods_receipt_path(receipt)
    expect(page).to have_css("html[dir='rtl']")
    stabilize_page!
    expect(page).to have_content("سجل التسويات المالية")
    expect(page).to have_content("تسوية جزئية")
    expect(no_horizontal_scroll?).to be true
    screenshot("mobile_ar_show")

    first(:link, "تسوية مالية").click
    expect(page).to have_content("تسجيل تسوية مالية")
    stabilize_page!
    choose "settlement_source_kind_employee_custody"
    expect(page).to have_content("رصيد العهدة")
    expect(page).to have_no_css("select")
    expect(no_horizontal_scroll?).to be true
    screenshot("mobile_ar_form")

    choose "settlement_source_kind_bank_account"
    fill_in "settlement_amount", with: "3000"
    accept_confirm { click_button "تسجيل التسوية" }
    expect(page).to have_content("تمت التسوية")
    expect(receipt.reload).to be_settled
    screenshot("mobile_ar_settled", tall: true)
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  it "form guards: my custody balance, live balance-after, and blocked invalid amounts" do
    sign_in admin
    visit new_inventory_goods_receipt_settlement_path(receipt)
    expect(page).to have_content(settlement_t("new_title"))
    stabilize_page!
    choose "settlement_source_kind_employee_custody"

    submit = find("input[type=submit]")
    expect(page).to have_no_css("select")
    expect(page).to have_css("[data-settlement-form-target='available']", text: "SAR 7,000.00")

    fill_in "settlement_amount", with: "2000"                   # live: 7,000 − 2,000
    expect(page).to have_css("[data-settlement-form-target='balanceAfter']", text: "SAR 5,000.00")
    expect(page).to have_css("[data-settlement-form-target='remainingAfter']", text: "SAR 3,000.00")
    expect(submit).not_to be_disabled

    fill_in "settlement_amount", with: "3000"                   # updates as the amount changes
    expect(page).to have_css("[data-settlement-form-target='balanceAfter']", text: "SAR 4,000.00")

    fill_in "settlement_amount", with: "6000"                   # > receipt remaining (5,000)
    expect(page).to have_content(settlement_t("errors.exceeds_remaining", remaining: "SAR 5,000.00"))
    expect(submit).to be_disabled

    fill_in "settlement_amount", with: "0"
    expect(page).to have_content(settlement_t("errors.amount_must_be_positive"))
    expect(submit).to be_disabled

    fill_in "settlement_amount", with: "-5"
    expect(submit).to be_disabled

    # Company cash: no custody balance involved — the balance-after row goes away.
    choose "settlement_source_kind_company_cash"
    fill_in "settlement_amount", with: "5000"
    expect(page).to have_no_css("[data-settlement-form-target='balanceAfterRow']", visible: true)
    expect(page).to have_css("[data-settlement-form-target='remainingAfter']", text: "0.00")
    expect(submit).not_to be_disabled
  end
end
