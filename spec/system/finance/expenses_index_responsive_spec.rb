require "rails_helper"

# Finance › Expenses index: an 8-column table while the list has room
# (≥860px of list width), one card per expense below that — switched by a
# container query on .expense-list, since the finance sidebars make the
# viewport a poor proxy (~770px of list at a 1024px screen). Widths via Chrome
# device emulation (headless Chrome can't shrink a real window below ~500px).
#
# Optional: EXPENSES_SCREENSHOT_DIR=/some/dir saves full-height captures.
RSpec.describe "Expenses index — responsive layout", type: :system do
  CARD_WIDTHS  = [ 390, 393, 768, 1024 ].freeze
  TABLE_WIDTHS = [ 1440 ].freeze

  let(:business) { create(:business, currency: "EGP") }
  let(:owner)    { create(:user, :owner, business: business, first_name: "Ahmed", last_name: "bahaa") }
  let(:branch)   { create(:branch, business: business, name: "صالون جدو - الترعة الجديدة بجوار مسجد النور الكبير") }
  let(:category) { create(:expense_category, business: business, name: "المرافق والخدمات العامة والصيانة الدورية للفروع") }
  let(:type)     { create(:expense_type, business: business, expense_category: category, name: "الإنترنت والاتصالات") }

  def expense(status, amount, **attrs)
    create(:expense, status, business: business, branch: branch, expense_category: category, expense_type: type,
                             amount: amount, created_by: owner, deduct_from_balance: false, **attrs)
  end

  let!(:pending)  { expense(:pending, 1_041) }
  let!(:approved) { expense(:approved, 125_000.5, payment_source: "not_linked_to_balance") }
  let!(:rejected) { expense(:rejected, 50) }

  after { page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") }

  def emulate(width, height: 1000)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: width, height: height, deviceScaleFactor: 1, mobile: width < 768)
  end

  def js(script) = page.evaluate_script(script)

  def screenshot(name, width)
    dir = ENV["EXPENSES_SCREENSHOT_DIR"]
    return if dir.blank?

    emulate(width, height: 2600)
    page.save_screenshot(File.join(dir, "#{name}.png"))
    emulate(width)
  end

  def card_mode? = js("getComputedStyle(document.querySelector('.expense-list__row')).display") == "grid"

  def row_for(expense) = find(".expense-list__row", text: expense.reference_number)

  def visit_index(locale, width)
    owner.update!(preferred_locale: locale)
    sign_in owner
    emulate(width)
    visit finance_expenses_path
    expect(page).to have_css(".expense-list__row", count: 3)
  end

  { "en" => "ltr", "ar" => "rtl" }.each do |locale, dir|
    CARD_WIDTHS.each do |width|
      it "#{locale.upcase} #{dir.upcase} @ #{width}px: cards in priority order, nothing clipped, tappable actions" do
        visit_index(locale, width)
        expect(page).to have_css("html[dir='#{dir}']")
        expect(card_mode?).to be(true)
        expect(js("document.documentElement.scrollWidth - window.innerWidth")).to be <= 1

        # Every card sits inside the viewport and no value is cut off.
        clipped = js(<<~JS)
          Array.from(document.querySelectorAll('.expense-list__row')).flatMap(card => {
            const r = card.getBoundingClientRect()
            const out = (r.left < -1 || r.right > window.innerWidth + 1) ? ['card off-screen'] : []
            return out.concat(Array.from(card.querySelectorAll('.expense-list__field > *, .expense-list__ref, .expense-list__amount'))
              .filter(el => el.scrollWidth > el.clientWidth + 1 || el.getBoundingClientRect().right > r.right + 1 || el.getBoundingClientRect().left < r.left - 1)
              .map(el => el.textContent.trim()))
          })
        JS
        expect(clipped).to be_empty, "clipped: #{clipped.inspect}"

        # Priority: reference + status on the first line, amount above the details.
        card = row_for(pending)
        ref_top    = card.find(".expense-list__ref").evaluate_script("this.getBoundingClientRect().top")
        status_top = card.find(".expense-list__status").evaluate_script("this.getBoundingClientRect().top")
        amount     = card.find(".expense-list__amount")
        type_top   = card.find(".expense-list__type").evaluate_script("this.getBoundingClientRect().top")
        expect((ref_top - status_top).abs).to be < 16
        expect(amount.evaluate_script("this.getBoundingClientRect().top")).to be < type_top

        # Amount never wraps; full branch/category names are shown (not truncated).
        line_height = amount.evaluate_script("parseFloat(getComputedStyle(this).lineHeight)")
        expect(amount.evaluate_script("this.getBoundingClientRect().height")).to be < line_height * 1.6
        expect(card).to have_text(branch.name)
        expect(card).to have_text(category.name)

        # Labels are visible and the status text is always present.
        # (badges render uppercase in English, hence the case-insensitive match)
        expect(card.text).to match(/#{Regexp.escape(I18n.t("finance.expenses.statuses.pending_approval", locale: locale))}/i)
        expect(js("getComputedStyle(document.querySelector('.expense-list__branch'), '::before').content"))
          .to include(I18n.t("finance.expenses.branch", locale: locale))

        # Action buttons are real touch targets.
        heights = card.all(".expense-list__action-group .btn").map { |b| b.evaluate_script("this.getBoundingClientRect().height") }
        expect(heights.size).to eq(3) # approve, reject, view
        expect(heights).to all(be >= 44)

        # Header: primary action visible, header buttons never overlap.
        overlaps = js(<<~JS)
          (() => {
            const rects = Array.from(document.querySelectorAll('.expenses-header-actions > *')).map(e => e.getBoundingClientRect())
            return rects.some((a, i) => rects.some((b, j) => i < j &&
              a.left < b.right - 1 && b.left < a.right - 1 && a.top < b.bottom - 1 && b.top < a.bottom - 1))
          })()
        JS
        expect(overlaps).to be(false)
        expect(page).to have_link(I18n.t("finance.expenses.add", locale: locale))

        screenshot("expenses_#{locale}_#{width}", width)
      end
    end

    TABLE_WIDTHS.each do |width|
      it "#{locale.upcase} #{dir.upcase} @ #{width}px: compact table fits without horizontal scrolling" do
        visit_index(locale, width)
        expect(card_mode?).to be(false)
        expect(page).to have_css(".expense-list thead th", count: 8, visible: :all)
        expect(js("document.documentElement.scrollWidth - window.innerWidth")).to be <= 1

        wrap = find(".expense-list__table")
        expect(wrap.evaluate_script("this.scrollWidth - this.clientWidth")).to be <= 1

        # Long names are clamped, with the full value available on hover.
        clamp = row_for(pending).find(".expense-list__branch .expense-list__clamp")
        expect(clamp[:title]).to eq(branch.name)
        expect(row_for(pending).find(".expense-list__amount").evaluate_script("getComputedStyle(this).whiteSpace")).to eq("nowrap")

        screenshot("expenses_#{locale}_#{width}", width)
      end
    end
  end

  it "groups the setup links in the Manage menu" do
    visit_index("ar", 390)

    expect(page).to have_no_link(I18n.t("finance.expenses.manage_categories", locale: "ar"))
    click_button I18n.t("finance.expenses.manage_menu", locale: "ar")
    expect(page).to have_link(I18n.t("finance.expenses.manage_categories", locale: "ar"), href: finance_expense_categories_path)
    expect(page).to have_link(I18n.t("finance.expenses.manage_types", locale: "ar"), href: finance_expense_types_path)
    expect(page).to have_link(I18n.t("finance.expenses.manage_tags", locale: "ar"), href: finance_expense_tags_path)
  end

  it "approves from a mobile card and stays on the filtered list" do
    visit_index("ar", 390)

    within(row_for(pending)) { click_button I18n.t("finance.expenses.actions.approve", locale: "ar") }

    expect(page).to have_css(".expense-list__row", text: pending.reference_number)
    expect(pending.reload).to be_approved
    expect(page).to have_current_path(finance_expenses_path)
  end

  it "rejects from a mobile card through the inline form, with a required reason" do
    visit_index("ar", 390)

    within(find(".expense-list__row", text: pending.reference_number).ancestor("tbody")) do
      click_button I18n.t("finance.expenses.actions.reject", locale: "ar")
      field = find("input[name='rejection_reason']")
      expect(field[:required]).to be_present
      expect(field.evaluate_script("this.getBoundingClientRect().height")).to be >= 44
      field.fill_in(with: "فاتورة مكررة")
      find("input[type='submit']").click
    end

    expect(page).to have_css(".expense-list__row", text: pending.reference_number)
    expect(pending.reload).to be_rejected
  end
end
