require "rails_helper"

# Employee Custody on the settlement form = the logged-in user's own custody:
# no employee selector; "Custody Balance" is the user's ledger balance and
# "Balance After Settlement" updates live as the amount changes — and may go
# NEGATIVE (custody is an accounting balance, not a spending limit). A user
# with no active custody account (e.g. super admin) sees an explanation and
# can't submit with Employee Custody.
RSpec.describe "Goods receipt settlement — own custody (browser)", type: :system do
  let(:business) { create(:business) }
  let(:role)     { create(:permission_role, business: business, permissions: %w[view_inventory approve_goods_receipts]) }
  let(:ahmed)    { create(:user, business: business, permission_role: role, first_name: "Ahmed", last_name: "Mounir") }
  let(:mohamed)  { create(:user, business: business) }
  let(:admin)    { create(:user, :super_admin, business: business) }

  let!(:ahmed_account)   { custody_for(ahmed, 14_027.32) }
  let!(:mohamed_account) { custody_for(mohamed, 50_000) }

  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product) do
    business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0)
  end
  let!(:receipt) do # 20,000
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current, funding_source_kind: "supplier_credit")
    r.items.build(product: product, quantity: 400, unit_cost: 50)
    r.save!
    r.update_column(:approval_status, "pending_approval")
    Inventory::GoodsReceiptApproval.new(goods_receipt_id: r.id, actor: admin).approve!
    r.reload
  end

  after { page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") }

  def custody_for(user, amount)
    account = create(:custody_account, business: business, user: user)
    account.custody_transactions.create!(business: business, txn_type: "top_up", amount: amount)
    account.refresh_balance!
    account
  end

  def t_s(key, locale: :en, **) = I18n.t("inventory.goods_receipts.settlements.#{key}", locale: locale, **)

  # Test-only: the app's smooth scrolling can make clicks land mid-animation.
  def stabilize_page!
    page.execute_script("document.documentElement.style.scrollBehavior = 'auto'")
    page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      const finite = document.getAnimations().filter(a => a.effect && a.effect.getComputedTiming().endTime !== Infinity);
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

  def within_viewport!(selector, width)
    left, right, w = page.evaluate_script(
      "(function(){ const r = document.querySelector(\"#{selector}\").getBoundingClientRect(); return [r.left, r.right, r.width]; })()"
    )
    expect(w).to be > 0, "#{selector} not rendered"
    expect(left).to be >= -1
    expect(right).to be <= width + 1
  end

  it "pays 5,000 from my custody end-to-end: 14,027.32 → 9,027.32, and reversal restores it" do
    sign_in ahmed
    visit new_inventory_goods_receipt_settlement_path(receipt)
    expect(page).to have_content(t_s(:new_title))
    stabilize_page!

    choose "settlement_source_kind_employee_custody"
    expect(page).to have_no_css("select")
    expect(page).to have_content(t_s(:custody_balance))
    expect(page).to have_css("[data-settlement-form-target='available']", text: "SAR 14,027.32")
    expect(page).to have_no_content("50,000.00")

    fill_in "settlement_amount", with: "5000"
    expect(page).to have_css("[data-settlement-form-target='balanceAfter']", text: "SAR 9,027.32")
    fill_in "settlement_amount", with: "15000"                    # more than my balance → negative, still allowed
    expect(page).to have_css("[data-settlement-form-target='balanceAfter'].text-danger", text: "SAR -972.68")
    expect(page).to have_no_content("insufficient", normalize_ws: true)
    expect(find("input[type=submit]")).not_to be_disabled
    fill_in "settlement_amount", with: "20000.01"                 # only the receipt's remaining limits it
    expect(page).to have_content(t_s("errors.exceeds_remaining", remaining: "SAR 20,000.00"))
    expect(find("input[type=submit]")).to be_disabled
    fill_in "settlement_amount", with: "0"
    expect(find("input[type=submit]")).to be_disabled
    fill_in "settlement_amount", with: "5000"
    expect(find("input[type=submit]")).not_to be_disabled

    accept_confirm { click_button t_s(:submit) }
    expect(page).to have_content(t_s(:recorded))

    settlement = receipt.financial_settlements.sole
    expect(settlement.funding_source).to eq(ahmed_account)
    expect(ahmed_account.reload.current_balance).to eq(9_027.32)
    expect(mohamed_account.reload.current_balance).to eq(50_000)

    Inventory::GoodsReceiptSettlementReverser.new(goods_receipt_id: receipt.id, settlement_id: settlement.id,
                                                  actor: admin, reason: "Mistake").call
    expect(ahmed_account.reload.current_balance).to eq(14_027.32)
  end

  { "en" => "SAR -1,000.00", "ar" => "-1,000.00" }.each do |locale, negative_text|
    it "FINAL SCENARIO (#{locale}): balance 1,000, receipt 2,000, pay 2,000 → −1,000 shown in red, succeeds, reversal → 1,000" do
      user = create(:user, business: business, permission_role: role, preferred_locale: locale)
      account = custody_for(user, 1_000)
      small = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current, funding_source_kind: "supplier_credit")
      small.items.build(product: product, quantity: 40, unit_cost: 50) # 2,000
      small.save!
      small.update_column(:approval_status, "pending_approval")
      Inventory::GoodsReceiptApproval.new(goods_receipt_id: small.id, actor: admin).approve!

      sign_in user
      visit new_inventory_goods_receipt_settlement_path(small)
      expect(page).to have_content(t_s(:new_title, locale: locale))
      stabilize_page!
      choose "settlement_source_kind_employee_custody"
      expect(page).to have_css("[data-settlement-form-target='available']", text: "1,000.00")

      fill_in "settlement_amount", with: "2000"
      after = find("[data-settlement-form-target='balanceAfter']")
      expect(after).to have_text(negative_text)
      expect(after[:class]).to include("text-danger")
      expect(page).to have_no_css("[data-settlement-form-target='error']", visible: true)  # no validation error
      expect(find("input[type=submit]")).not_to be_disabled

      accept_confirm { click_button t_s(:submit, locale: locale) }
      expect(page).to have_content(t_s(:recorded, locale: locale))

      settlement = small.reload.financial_settlements.sole
      expect(settlement.custody_transaction.amount).to eq(-2_000)
      expect(account.reload.current_balance).to eq(-1_000)
      expect(small.total_settled_amount).to eq(2_000)
      expect(small.remaining_settlement_amount).to eq(0)

      Inventory::GoodsReceiptSettlementReverser.new(goods_receipt_id: small.id, settlement_id: settlement.id,
                                                    actor: admin, reason: "Reverse").call
      expect(account.reload.current_balance).to eq(1_000)
    end
  end

  it "a user with no custody account sees the explanation and cannot submit Employee Custody" do
    sign_in admin
    visit new_inventory_goods_receipt_settlement_path(receipt)
    expect(page).to have_content(t_s(:new_title))
    stabilize_page!

    choose "settlement_source_kind_employee_custody"
    expect(page).to have_content(t_s("errors.no_custody_account"))
    expect(find("input[type=submit]")).to be_disabled
    expect(page).to have_no_content("50,000.00")                  # never someone else's custody

    choose "settlement_source_kind_company_cash"                  # other sources unaffected
    expect(find("input[type=submit]")).not_to be_disabled
  end

  { "en" => "ltr", "ar" => "rtl" }.each do |locale, dir|
    [ 430, 390, 375 ].each do |width|
      it "#{locale.upcase} #{dir.upcase} @ #{width}px: custody balance, amount, balance-after visible; no overflow" do
        ahmed.update!(preferred_locale: locale)
        sign_in ahmed
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                        width: width, height: 900, deviceScaleFactor: 1, mobile: true)
        visit new_inventory_goods_receipt_settlement_path(receipt)
        expect(page).to have_css("html[dir='#{dir}']")
        stabilize_page!

        choose "settlement_source_kind_employee_custody"
        expect(page).to have_no_css("select")
        expect(page).to have_content(t_s(:custody_balance, locale: locale))
        expect(page).to have_css("[data-settlement-form-target='available']", text: "14,027.32")
        fill_in "settlement_amount", with: "5000"
        expect(page).to have_content(t_s(:balance_after, locale: locale))
        expect(page).to have_css("[data-settlement-form-target='balanceAfter']", text: "9,027.32")
        fill_in "settlement_amount", with: "15000"                  # negative result stays readable & allowed
        expect(page).to have_css("[data-settlement-form-target='balanceAfter'].text-danger", text: "972.68")
        expect(find("input[type=submit]")).not_to be_disabled

        %w[[data-settlement-form-target='available'] #settlement_amount
           [data-settlement-form-target='balanceAfter'] input[type=submit]].each { |sel| within_viewport!(sel, width) }
        expect(page.evaluate_script("document.documentElement.scrollWidth - window.innerWidth")).to be <= 1
      end
    end
  end
end
