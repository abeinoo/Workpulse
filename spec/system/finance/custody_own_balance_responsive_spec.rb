require "rails_helper"

# Employee's own custody view (Finance › Employee Balances for a user without
# balance permissions): the 4-column ledger (Date, Type, Amount, Notes) under
# the balance card. Desktop keeps the table; ≤768px shows the same cards as the
# account page's ledger. Widths via Chrome device emulation (headless Chrome
# can't shrink a real window below ~500px).
#
# Optional: SETTLEMENT_SCREENSHOT_DIR=/some/dir saves full-height captures.
RSpec.describe "Employee own custody ledger — responsive layout", type: :system do
  WIDTHS = [ 1440, 1280, 1024, 430, 390, 375 ].freeze
  FIELDS = %w[date type amount notes].freeze

  let(:business) { create(:business) }
  let(:role)     { create(:permission_role, business: business, permissions: %w[view_expenses create_expenses]) }
  let(:employee) do
    create(:user, business: business, permission_role: role,
                  first_name: "Mohamed", last_name: "Abdelrahman Elsayed Mahmoud Ibrahim Elshenawy")
  end
  let!(:account) { create(:custody_account, business: business, user: employee, name: "Mohamed Main Float") }

  let!(:top_up) do
    account.custody_transactions.create!(business: business, txn_type: "top_up", amount: 12_500)
  end
  let!(:long_note) do
    account.custody_transactions.create!(
      business: business, txn_type: "adjustment", amount: -1_234_567.89,
      notes: "Supplier invoice INV-2026-000912-NILEBEAUTY-SUPPLIESCOMPANY reconciliation — مطابقة فاتورة المورد GRN-000082"
    )
  end
  let!(:voided) do
    account.custody_transactions.create!(business: business, txn_type: "adjustment", amount: -50,
                                         voided_at: Time.current, void_reason: "typo")
  end

  before { account.refresh_balance! }
  after  { page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") }

  def emulate(width, height: 900)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: width, height: height, deviceScaleFactor: 1, mobile: width < 768)
  end

  def screenshot(name, width)
    dir = ENV["SETTLEMENT_SCREENSHOT_DIR"]
    return if dir.blank?

    emulate(width, height: 2200)
    page.save_screenshot(File.join(dir, "#{name}.png"))
    emulate(width)
  end

  def js(script) = page.evaluate_script(script)

  def business_date_of(time) = time.in_time_zone(business.timezone_object).to_date

  def assert_no_page_overflow(context)
    overflow = js("document.documentElement.scrollWidth - window.innerWidth")
    expect(overflow).to be <= 1, "#{context}: page scrolls horizontally by #{overflow}px"
  end

  def assert_within_viewport(element, context)
    left, right, width = js("(function(el){ const r = el.getBoundingClientRect(); return [r.left, r.right, r.width]; })(arguments[0])".sub("arguments[0]", "document.querySelector('#{element}')"))
    expect(width).to be > 0, "#{context}: not rendered"
    expect(left).to be >= -1, "#{context}: starts off-screen (#{left})"
    expect(right).to be <= js("window.innerWidth") + 1, "#{context}: ends off-screen (#{right})"
  end

  { "en" => "ltr", "ar" => "rtl" }.each do |locale, dir|
    WIDTHS.each do |width|
      it "#{locale.upcase} #{dir.upcase} @ #{width}px: own ledger fits, all four fields readable" do
        employee.update!(preferred_locale: locale)
        sign_in employee
        emulate(width)
        visit finance_custody_accounts_path
        tag = "#{locale}_#{width}"

        expect(page).to have_css("html[dir='#{dir}']")
        expect(js("window.innerWidth")).to eq(width)
        expect(page).to have_content(I18n.t("finance.custody.transactions.ledger", locale: locale))
        assert_no_page_overflow("#{tag} own balance page")

        list_overflow = js("(function(){ const w = document.querySelector('.custody-ledger'); return w.scrollWidth - w.clientWidth; })()")
        mobile = width < 768

        [ top_up, long_note, voided ].each do |txn|
          row = "#my-txn-#{txn.id}"
          page.execute_script("document.querySelector('#{row}').scrollIntoView({ block: 'center', behavior: 'instant' })")
          within(row) do
            # Badges are uppercased by CSS.
            expect(page).to have_content(/#{Regexp.escape(I18n.t("finance.custody.transactions.types.#{txn.txn_type}", locale: locale))}/i)
            # The page renders the date inside the business timezone (set_business_timezone);
            # the UTC date differs every evening (21:00–24:00 UTC for Asia/Riyadh).
            expect(page).to have_content(I18n.l(business_date_of(txn.created_at), format: :long, locale: locale))
          end
        end
        within("#my-txn-#{long_note.id}") do
          expect(page).to have_content("1,234,567.89")
          expect(page).to have_content("INV-2026-000912-NILEBEAUTY-SUPPLIESCOMPANY")
          expect(page).to have_content("GRN-000082")
        end
        within("#my-txn-#{voided.id}") do
          expect(page).to have_content(/#{Regexp.escape(I18n.t("finance.custody.transactions.voided_label", locale: locale))}/i)
        end

        if mobile
          expect(list_overflow).to be <= 1, "#{tag} own ledger scrolls horizontally by #{list_overflow}px"
          expect(js("getComputedStyle(document.querySelector('.custody-ledger thead')).display")).to eq("none")
          FIELDS.each do |field|
            assert_within_viewport("#my-txn-#{long_note.id} .custody-ledger__#{field}", "#{tag} card #{field}")
          end
          # Same hierarchy as the account-page cards: amount first, then type, then date.
          tops = js("['amount','type','date','notes'].map(f => document.querySelector('#my-txn-#{long_note.id} .custody-ledger__' + f).getBoundingClientRect().top)")
          expect(tops).to eq(tops.sort), "#{tag} card order (tops=#{tops.inspect})"
          expect(js("parseFloat(getComputedStyle(document.querySelector('#my-txn-#{long_note.id} .custody-ledger__amount')).fontWeight)")).to be >= 700
        else
          # Desktop: unchanged 4-column table.
          expect(js("getComputedStyle(document.querySelector('.custody-ledger thead')).display")).to eq("table-header-group")
          expect(all(".custody-ledger thead th").size).to eq(4)
          expect(js("getComputedStyle(document.querySelector('#my-txn-#{long_note.id}')).display")).to eq("table-row")
        end

        # The ledger has no row actions (unchanged). The balance card above it
        # still shows the account balance. (Its "New Balance Request" button
        # needs create_balance_requests, which implies view_employee_balances →
        # the manager view, so it never appears in this employee view.)
        balance = account.reload.computed_balance
        expect(page).to have_content(ActiveSupport::NumberHelper.number_to_rounded(balance.abs, precision: 2, delimiter: ","))
        assert_within_viewport(".card .detail-list", "#{tag} balance card")
        screenshot("own_#{tag}", width)
      end
    end
  end

  it "keeps the no-account empty state intact on a phone" do
    other = create(:user, business: business, permission_role: role, preferred_locale: "ar")
    sign_in other
    emulate(375)
    visit finance_custody_accounts_path

    expect(page).to have_content(I18n.t("finance.custody.accounts.no_account", locale: :ar))
    expect(page).to have_no_css(".custody-ledger")
    assert_no_page_overflow("empty state @375")
  end
end
