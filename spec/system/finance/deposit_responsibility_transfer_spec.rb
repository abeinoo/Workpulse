require "rails_helper"

# Transfer Deposit Responsibility, in the browser: a manager requests a
# transfer, the recipient accepts or rejects it from the request card.
# Widths via Chrome device emulation (headless Chrome can't shrink a real
# window below ~500px), same approach as custody_own_balance_responsive_spec.
#
# Optional: DEPOSIT_TRANSFER_SCREENSHOT_DIR=/some/dir saves captures.
RSpec.describe "Transfer Deposit Responsibility", type: :system do
  widths = [ 1440, 1280, 1024, 768, 430, 390, 375 ].freeze

  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business, name: "صالون جدو - مدينة نصر — Gedo Salon Nasr City") }
  let!(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  def user_with(*perms, **attrs)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}", permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: business, **attrs).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:manager) do
    user_with("view_daily_reconciliation", "verify_daily_reconciliation", first_name: "Sara", last_name: "Manager")
  end
  let!(:ahmed)   { user_with("close_till_session", "create_till_deposit", first_name: "أحمد", last_name: "بهاء") }
  let!(:mohamed) { user_with("close_till_session", "create_till_deposit", first_name: "محمد", last_name: "أحمد عبد الرحمن السيد") }
  let(:mohamed_name) { "محمد أحمد عبد الرحمن السيد" }

  let!(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 2.hours.ago, closed_at: 1.hour.ago, business_date: Date.current
    )
  end
  let!(:session) { TillSession.create!(daily_reconciliation: dr, depositor: ahmed, closed_by: ahmed) }
  let!(:amount) do
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                              collected_amount: 1_000, refund_amount: 0)
  end

  def pending_transfer!(notes: "أحمد في إجازة — Ahmed is on leave today")
    DepositResponsibilityTransfer.create!(daily_reconciliation: dr, from_user: ahmed, to_user: mohamed,
                                          initiated_by: manager, notes: notes)
  end

  after { page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") }

  def emulate(width, height: 900)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: width, height: height, deviceScaleFactor: 1, mobile: width < 768)
  end

  def js(script) = page.evaluate_script(script)

  def rect(selector)
    js("(function(){ const r = document.querySelector(#{selector.to_json}).getBoundingClientRect(); " \
       "return { left: r.left, right: r.right, top: r.top, bottom: r.bottom, width: r.width }; })()")
  end

  def assert_no_page_overflow(context)
    overflow = js("document.documentElement.scrollWidth - window.innerWidth")
    expect(overflow).to be <= 1, "#{context}: page scrolls horizontally by #{overflow}px"
  end

  def assert_no_inner_overflow(selector, context)
    overflow = js("(function(){ const m = document.querySelector(#{selector.to_json}); return m.scrollWidth - m.clientWidth; })()")
    expect(overflow).to be <= 1, "#{context}: #{selector} scrolls horizontally by #{overflow}px"
  end

  def assert_fully_visible(selector, context)
    page.execute_script("document.querySelector(#{selector.to_json}).scrollIntoView({ block: 'nearest', behavior: 'instant' })")
    r = rect(selector)
    expect(r["width"]).to be > 0, "#{context}: #{selector} not rendered"
    expect(r["left"]).to be >= -1, "#{context}: #{selector} starts off-screen (#{r['left']})"
    expect(r["right"]).to be <= js("window.innerWidth") + 1, "#{context}: #{selector} ends off-screen (#{r['right']})"
    expect(r["top"]).to be >= -1, "#{context}: #{selector} above viewport"
    expect(r["bottom"]).to be <= js("window.innerHeight") + 1, "#{context}: #{selector} below viewport"
  end

  def screenshot(name)
    dir = ENV["DEPOSIT_TRANSFER_SCREENSHOT_DIR"]
    page.save_screenshot(File.join(dir, "#{name}.png")) if dir.present?
  end

  { "ar" => "rtl", "en" => "ltr" }.each do |locale, dir|
    widths.each do |width|
      it "#{locale.upcase} #{dir.upcase} @ #{width}px: every transfer card and modal fits without horizontal overflow" do
        tag = "#{locale}_#{width}"
        [ manager, mohamed ].each { |u| u.update!(preferred_locale: locale) }
        emulate(width)

        # ── Manager: transfer action + request modal ────────────────────────
        sign_in manager
        visit finance_daily_reconciliation_path(dr)
        expect(page).to have_css("html[dir='#{dir}']")
        expect(js("window.innerWidth")).to eq(width)
        assert_no_page_overflow("#{tag} manager DR page")
        assert_fully_visible("#transfer-deposit-responsibility-button", "#{tag} transfer button")

        find("#transfer-deposit-responsibility-button").click
        expect(page).to have_css("#deposit-transfer-modal", visible: true)
        find("select#deposit-transfer-depositor").select(mohamed_name)
        assert_no_page_overflow("#{tag} request modal")
        assert_no_inner_overflow("#deposit-transfer-modal", "#{tag} request modal")
        %w[select#deposit-transfer-depositor textarea#deposit-transfer-notes #deposit-transfer-submit].each do |sel|
          assert_fully_visible(sel, "#{tag} request modal")
        end
        assert_fully_visible("#deposit-transfer-form button[data-action='click->modal#close']", "#{tag} request modal cancel")
        screenshot("request_modal_#{tag}")
        find("#deposit-transfer-form button[data-action='click->modal#close']").click

        # ── Manager: pending state on the depositor card ───────────────────
        pending_transfer!
        visit finance_daily_reconciliation_path(dr)
        within("#deposit-responsibility-card") do
          expect(page).to have_content("أحمد بهاء")
          # Badges are uppercased by CSS.
          expect(page).to have_content(/#{Regexp.escape(I18n.t("finance.daily_reconciliations.transfer_deposit.pending_badge", locale: locale))}/i)
          expect(page).to have_content(mohamed_name)
        end
        assert_no_page_overflow("#{tag} manager pending card")
        assert_no_inner_overflow("#deposit-responsibility-card", "#{tag} pending card")
        assert_fully_visible("#deposit-transfer-cancel-form button", "#{tag} cancel transfer button")
        screenshot("pending_card_#{tag}")

        # ── Recipient: request card, accept modal, reject modal ────────────
        sign_in mohamed
        visit finance_daily_reconciliation_path(dr)
        within("#deposit-transfer-request-card") do
          expect(page).to have_content(I18n.t("finance.daily_reconciliations.show.deposit_request.title", locale: locale))
          expect(page).to have_content("أحمد بهاء")
          expect(page).to have_content("Sara Manager")
        end
        assert_no_page_overflow("#{tag} recipient DR page")
        assert_no_inner_overflow("#deposit-transfer-request-card", "#{tag} request card")
        assert_fully_visible("#deposit-request-accept", "#{tag} accept button")
        assert_fully_visible("#deposit-request-reject", "#{tag} reject button")
        screenshot("request_card_#{tag}")

        find("#deposit-request-accept").click
        expect(page).to have_content(I18n.t("deposit_responsibility_transfers.show.confirm_accept", locale: locale))
        assert_no_page_overflow("#{tag} accept modal")
        assert_fully_visible("#deposit-accept-submit", "#{tag} accept modal confirm")
        assert_fully_visible("#deposit-accept-form button[data-action='click->modal#close']", "#{tag} accept modal cancel")
        screenshot("accept_modal_#{tag}")
        find("#deposit-accept-form button[data-action='click->modal#close']").click
        expect(page).to have_no_css("#deposit-accept-form", visible: true)

        find("#deposit-request-reject").click
        expect(page).to have_css("#deposit-reject-modal", visible: true)
        assert_no_page_overflow("#{tag} reject modal")
        assert_no_inner_overflow("#deposit-reject-modal", "#{tag} reject modal")
        %w[textarea#deposit-reject-reason #deposit-reject-submit].each { |sel| assert_fully_visible(sel, "#{tag} reject modal") }
        assert_fully_visible("#deposit-reject-form button[data-action='click->modal#close']", "#{tag} reject modal cancel")
        screenshot("reject_modal_#{tag}")

        # Nothing above changed who is responsible.
        expect(session.reload.depositor).to eq(ahmed)
      end
    end
  end

  it "manager request only happens after explicit confirmation and does not change the depositor (Arabic, 390px)" do
    manager.update!(preferred_locale: "ar")
    sign_in manager
    emulate(390)
    visit finance_daily_reconciliation_path(dr)
    find("#transfer-deposit-responsibility-button").click

    expect(find("#deposit-transfer-submit")).to be_disabled
    find("select#deposit-transfer-depositor").select(mohamed_name)
    confirm_text = I18n.t("finance.daily_reconciliations.transfer_deposit.confirm", name: mohamed_name, locale: :ar)

    dismiss_confirm(confirm_text) { find("#deposit-transfer-submit").click }
    expect(DepositResponsibilityTransfer.count).to eq(0)

    accept_confirm(confirm_text) { find("#deposit-transfer-submit").click }
    expect(page).to have_content(I18n.t("deposit_responsibility_transfers.requested", name: mohamed_name, locale: :ar))
    within("#deposit-responsibility-card") do
      expect(page).to have_content("أحمد بهاء")
      expect(page).to have_content(I18n.t("finance.daily_reconciliations.transfer_deposit.pending_badge", locale: :ar))
    end
    expect(session.reload.depositor).to eq(ahmed)
    expect(DepositResponsibilityTransfer.sole).to be_pending
  end

  it "recipient accepts through the confirmation step and becomes the depositor (English, 375px)" do
    transfer = pending_transfer!
    sign_in mohamed
    emulate(375)
    visit finance_daily_reconciliation_path(dr)
    expect(session.reload.depositor).to eq(ahmed) # opening the page accepts nothing

    find("#deposit-request-accept").click
    expect(page).to have_content(I18n.t("deposit_responsibility_transfers.show.confirm_accept"))
    find("#deposit-accept-submit").click

    expect(page).to have_content(I18n.t("deposit_responsibility_transfers.accepted"))
    expect(page).to have_no_css("#deposit-transfer-request-card")
    expect(find("#deposit-responsibility-name")).to have_content(mohamed_name)
    expect(session.reload.depositor).to eq(mohamed)
    expect(transfer.reload.accepted_by).to eq(mohamed)
    assert_no_page_overflow("after accept @375")
  end

  it "recipient rejects with a reason; the old depositor stays and the timeline shows the reason (Arabic, 430px)" do
    transfer = pending_transfer!
    [ mohamed, manager ].each { |u| u.update!(preferred_locale: "ar") }
    sign_in mohamed
    emulate(430)
    visit finance_daily_reconciliation_path(dr)

    find("#deposit-request-reject").click
    fill_in "deposit-reject-reason", with: "لدي إجازة غدًا"
    find("#deposit-reject-submit").click

    expect(page).to have_content(I18n.t("deposit_responsibility_transfers.rejected", locale: :ar))
    expect(session.reload.depositor).to eq(ahmed)
    expect(transfer.reload.rejection_reason).to eq("لدي إجازة غدًا")

    # Switch users on a fresh browser session. Mohamed's page can still fire a
    # Turbo hover prefetch; one reaching the server after `sign_in manager`
    # consumes that one-shot login, and the manager's visit — already sent with
    # Mohamed's cookie — renders as Mohamed (no transfer button). Resetting
    # leaves the page, waits for in-flight requests and clears the cookies.
    Capybara.reset_session!
    sign_in manager
    emulate(430)
    visit finance_daily_reconciliation_path(dr)
    find("#audit-log .recon-accordion__trigger").click
    expect(page).to have_content(I18n.t("finance.daily_reconciliations.show.timeline.deposit_rejected",
                                        name: mohamed_name, locale: :ar))
    expect(page).to have_content("لدي إجازة غدًا")
    expect(page).to have_css("#transfer-deposit-responsibility-button") # a new transfer can be requested
    assert_no_page_overflow("after reject @430")
  end
end
