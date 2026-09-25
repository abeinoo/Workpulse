require "rails_helper"

# Viewport matrix for the goods receipt settlement UI: detail page (status,
# payment history, reversal), settlement form (own custody balance,
# amount, live guidance) at 3 desktop and 3 phone widths, in English LTR and
# Arabic RTL. Widths are applied with Chrome device emulation — a real window
# can't shrink below ~500px in headless Chrome, so resize_to would silently
# test a wider viewport than asked for.
#
# Optional: SETTLEMENT_SCREENSHOT_DIR=/some/dir saves a full-height capture of
# every page/width/locale combination for visual review.
RSpec.describe "Goods receipt settlement — responsive layout", type: :system do
  DESKTOP_WIDTHS = [ 1440, 1280, 1024 ].freeze
  MOBILE_WIDTHS  = [ 430, 390, 375 ].freeze

  let(:business)  { create(:business) }
  let(:admin)     { create(:user, :super_admin, business: business, first_name: "Ahmed", last_name: "Hassan Abdelrahman Mohamed Elsayed") }
  let(:warehouse) { business.warehouses.create!(name: "Main Warehouse") }
  let(:supplier)  { business.suppliers.create!(name: "Nile Beauty Supplies Co.") }
  let(:product) do
    business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0)
  end
  # Employee Custody is always the logged-in user's (admin's) own account.
  let!(:account) { create(:custody_account, business: business, user: admin, name: "Ahmed Main Float") }

  let!(:receipt) do
    r = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current,
                                      funding_source_kind: "supplier_credit")
    r.items.build(product: product, quantity: 100, unit_cost: 50)
    r.save!
    r.update_column(:approval_status, "pending_approval")
    Inventory::GoodsReceiptApproval.new(goods_receipt_id: r.id, actor: admin).approve!
    r.reload
  end

  # History with every row state: a reversed custody payment, its reversal
  # entry, and an active company-cash payment → partially settled (1,500 / 5,000).
  before do
    account.custody_transactions.create!(business: business, txn_type: "top_up", amount: 7_000)
    account.refresh_balance!
    wrong = record(source_kind: "employee_custody", amount: "2000", reference: "BANK-TRX-0098812")
    Inventory::GoodsReceiptSettlementReverser.new(goods_receipt_id: receipt.id, settlement_id: wrong.id,
                                                  actor: admin, reason: "Recorded from the wrong employee custody").call
    record(source_kind: "company_cash", amount: "1500", reference: "CASH-VOUCHER-771", notes: "Paid at the branch")
  end

  after { page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") }

  def record(**params)
    Inventory::GoodsReceiptSettlementRecorder.new(receipt.id, actor: admin, params: params).call.settlement
  end

  def emulate(width, height: 900)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: width, height: height, deviceScaleFactor: 1, mobile: width < 768)
  end

  def screenshot(name, width)
    dir = ENV["SETTLEMENT_SCREENSHOT_DIR"]
    return if dir.blank?

    emulate(width, height: 3400)
    page.save_screenshot(File.join(dir, "#{name}.png"))
    emulate(width)
  end

  def viewport_width = page.evaluate_script("window.innerWidth")

  def assert_no_horizontal_overflow(context)
    overflow = page.evaluate_script("document.documentElement.scrollWidth - window.innerWidth")
    expect(overflow).to be <= 1, "#{context}: page scrolls horizontally by #{overflow}px"
  end

  # Fully reachable without horizontal scrolling (page or inner scroll box).
  def assert_within_viewport(element, context)
    rect = page.evaluate_script("(function(el){ const r = el.getBoundingClientRect(); return [r.left, r.right, r.width]; })(arguments[0])", element)
    left, right, width = rect
    expect(width).to be > 0, "#{context}: element not rendered"
    expect(left).to be >= -1, "#{context}: starts off-screen (left=#{left})"
    expect(right).to be <= viewport_width + 1, "#{context}: ends off-screen (right=#{right}, viewport=#{viewport_width})"
  end

  { "en" => "ltr", "ar" => "rtl" }.each do |locale, dir|
    (DESKTOP_WIDTHS + MOBILE_WIDTHS).each do |width|
      it "#{locale.upcase} #{dir.upcase} @ #{width}px: detail page, history, reversal, and settlement form are usable" do
        admin.update!(preferred_locale: locale)
        sign_in admin
        emulate(width)
        tag = "#{locale}_#{width}"
        t_s = ->(key, **opts) { I18n.t("inventory.goods_receipts.settlements.#{key}", locale: locale, **opts) }

        # ── Detail page ────────────────────────────────────────────────
        visit inventory_goods_receipt_path(receipt)
        expect(page).to have_css("html[dir='#{dir}']")
        expect(viewport_width).to eq(width)
        assert_no_horizontal_overflow("#{tag} detail")

        status = I18n.t("inventory.goods_receipts.financial_statuses.partially_settled", locale: locale)
        expect(page).to have_content(/#{Regexp.escape(status)}/i)
        expect(page).to have_content(t_s.call(:history_title))

        if width >= 768
          # Desktop: the whole history table is visible — no sideways scrolling inside it.
          inner = page.evaluate_script(
            "(function(){ const w = document.querySelector('[id^=settlement-]').closest('.table-wrap'); return w.scrollWidth - w.clientWidth; })()"
          )
          expect(inner).to be <= 1, "#{tag} history table scrolls horizontally by #{inner}px"
        end

        settle_button = first(:link, t_s.call(:action))
        assert_within_viewport(settle_button, "#{tag} settle button")

        active_row = receipt.financial_settlements.unreversed.last
        reverse_summary = find("#settlement-#{active_row.id} summary")
        page.scroll_to(reverse_summary)
        assert_within_viewport(reverse_summary, "#{tag} reverse action")
        within("#settlement-#{active_row.id}") do
          expect(page).to have_content(/#{Regexp.escape(t_s.call("statuses.active"))}/i)
        end
        reversed_row = receipt.financial_settlements.originals.find(&:reversed?)
        within("#settlement-#{reversed_row.id}") do
          expect(page).to have_content(/#{Regexp.escape(t_s.call("statuses.reversed"))}/i)
          expect(page).to have_content("Recorded from the wrong employee custody")
          expect(page).to have_content(t_s.call(:custody_transaction_ref, id: reversed_row.custody_transaction.id))
        end

        # Reversal form opens and fits.
        reverse_summary.click
        textarea = find("#reversal_reason_#{active_row.id}")
        assert_within_viewport(textarea, "#{tag} reversal reason")
        assert_within_viewport(find("#settlement-#{active_row.id} button[type=submit]"), "#{tag} reversal submit")
        assert_no_horizontal_overflow("#{tag} detail with reversal open")
        screenshot("#{tag}_detail", width)

        # ── Settlement form ────────────────────────────────────────────
        visit new_inventory_goods_receipt_settlement_path(receipt)
        assert_no_horizontal_overflow("#{tag} form")
        choose "settlement_source_kind_employee_custody"
        expect(page).to have_no_css("select")                        # no employee selector
        expect(page).to have_css("[data-settlement-form-target='available']", text: "7,000.00")

        fill_in "settlement_amount", with: "2000"
        expect(page).to have_css("[data-settlement-form-target='remainingAfter']", text: "1,500.00")
        # My custody balance after this settlement: 7,000 − 2,000.
        expect(page).to have_css("[data-settlement-form-target='balanceAfter']", text: "5,000.00")
        assert_within_viewport(find("[data-settlement-form-target='available']"), "#{tag} custody balance")
        assert_within_viewport(find("[data-settlement-form-target='balanceAfter']"), "#{tag} balance after")
        assert_within_viewport(find("#settlement_amount"), "#{tag} amount field")
        submit = find("input[type=submit]")
        assert_within_viewport(submit, "#{tag} submit")
        expect(submit).not_to be_disabled
        assert_no_horizontal_overflow("#{tag} form filled")
        screenshot("#{tag}_form", width)

        # ── Custody account page: ledger (cards on phones) ─────────────
        visit finance_custody_account_path(account)
        assert_no_horizontal_overflow("#{tag} custody page")
        ledger_overflow = page.evaluate_script(
          "(function(){ const w = document.querySelector('.custody-ledger'); return w.scrollWidth - w.clientWidth; })()"
        )
        if width < 768
          # Cards: nothing hidden sideways inside the list either.
          expect(ledger_overflow).to be <= 1, "#{tag} custody list scrolls horizontally by #{ledger_overflow}px"
        end

        t_c = ->(key, **opts) { I18n.t("finance.custody.transactions.#{key}", locale: locale, **opts) }
        linked = reversed_row.custody_transaction
        normal = account.custody_transactions.of_type("top_up").first
        # behavior: "instant" — the app uses smooth scrolling, and measuring/clicking
        # mid-animation is flaky.
        page.execute_script("document.getElementById('txn-#{linked.id}').scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' })")

        within("#txn-#{linked.id}") do
          expect(page).to have_content(t_c.call(:settlement_linked_badge))
          expect(page).to have_content(t_c.call(:settlement_linked_hint))
          expect(page).to have_link(t_c.call(:view_settlement))
          expect(page).not_to have_button(t_c.call(:void))
          expect(page).to have_link(receipt.receipt_number)
          expect(page).to have_content(admin.full_name)
        end
        within("#txn-#{normal.id}") do
          expect(page).to have_button(t_c.call(:void))           # normal rows keep their action
          expect(page).not_to have_content(t_c.call(:settlement_linked_badge))
        end

        if width < 768
          card = find("#txn-#{linked.id}")
          # Every field fits the card width; the amount is the first thing in the card.
          %w[amount type date by ref running notes actions].each do |field|
            assert_within_viewport(card.find(".custody-ledger__#{field}"), "#{tag} custody card #{field}")
          end
          expect(page).to have_css("#txn-#{linked.id} .custody-ledger__id", text: t_c.call(:txn_ref, id: linked.id))
          # One snapshot, so all three positions are measured at the same instant.
          tops = page.evaluate_script(
            "['amount','type','date'].map(f => document.querySelector('#txn-#{linked.id} .custody-ledger__' + f).getBoundingClientRect().top)"
          )
          expect(tops).to eq(tops.sort), "#{tag} card order should be amount → type → date (tops=#{tops.inspect})"
        else
          expect(page).to have_no_css("#txn-#{linked.id} .custody-ledger__id", visible: true) # desktop table unchanged
        end
        screenshot("#{tag}_custody", width)

        # "View settlement" lands on the exact settlement row of the receipt.
        view_link = find("#txn-#{linked.id}").find_link(t_c.call(:view_settlement))
        page.execute_script("arguments[0].scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' })", view_link)
        view_link.click
        expect(page).to have_current_path(inventory_goods_receipt_path(receipt))
        expect(page.evaluate_script("window.location.hash")).to eq("#settlement-#{reversed_row.id}")
        expect(page).to have_css("#settlement-#{reversed_row.id}")
      end
    end
  end
end
