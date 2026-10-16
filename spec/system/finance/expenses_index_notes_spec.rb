require "rails_helper"

# Finance › Expenses index — each expense's notes (Expense#notes) in the list,
# display only:
#   • wide lists (≥1040px of list, i.e. ≥~1600px screens; Arabic): a
#     "ملاحظات" column after the amount — two lines then "…", full text on
#     hover (title) or "عرض المزيد";
#   • narrower desktop lists (860–1039px, e.g. 1440px beside the finance
#     sidebars — and English up to 1079px, whose columns are wider): the same
#     note under the amount, so no other column is squeezed;
#   • cards (<860px): a labelled "ملاحظات" section, only when there is a note.
#
# Optional: EXPENSES_SCREENSHOT_DIR=/some/dir saves captures.
RSpec.describe "Expenses index — notes", type: :system do
  let(:business) { create(:business, currency: "EGP") }
  let(:owner)    { create(:user, :owner, business: business, preferred_locale: "ar") }
  let(:branch)   { create(:branch, business: business, name: "فرع المعادي") }
  let(:category) { create(:expense_category, business: business, name: "المرافق") }

  SHORT_NOTE  = "فاتورة الكهرباء".freeze
  MIXED_NOTE  = "تم دفع 1,250.75 جنيه لفاتورة رقم 4587 لشهر 10/2026".freeze
  LONG_NOTE   = ("تم صرف هذا المبلغ لصيانة أجهزة التكييف في الفرع بعد تعطلها خلال موجة الحر، " * 4).strip.freeze

  def expense(notes, amount: 1_000)
    create(:expense, :pending, business: business, branch: branch, expense_category: category,
                               amount: amount, notes: notes, created_by: owner, deduct_from_balance: false)
  end

  let!(:without) { expense(nil, amount: 50) }
  let!(:short)   { expense(SHORT_NOTE) }
  let!(:mixed)   { expense(MIXED_NOTE) }
  let!(:long)    { expense(LONG_NOTE, amount: 125_000.5) }

  after { page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") }

  def emulate(width, height: 1100)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: width, height: height, deviceScaleFactor: 1, mobile: width < 768)
  end

  def js(script) = page.evaluate_script(script)
  def row_for(expense) = find(".expense-list__row", text: expense.reference_number)

  def screenshot(name, width)
    dir = ENV["EXPENSES_SCREENSHOT_DIR"]
    return if dir.blank?

    emulate(width, height: 1800)
    page.save_screenshot(File.join(dir, "#{name}.png"))
    emulate(width)
  end

  def visit_at(width)
    sign_in owner
    emulate(width)
    visit finance_expenses_path
    expect(page).to have_css("html[dir='rtl']")
    expect(page).to have_css(".expense-list__row", count: 4)
  end

  def expect_no_overflow
    expect(js("document.documentElement.scrollWidth - window.innerWidth")).to be <= 1
    expect(js("(w => w.scrollWidth - w.clientWidth)(document.querySelector('.expense-list__table'))")).to be <= 1
  end

  def lines(element)
    element.evaluate_script("(() => { const s = getComputedStyle(this);
      return Math.round(this.getBoundingClientRect().height / parseFloat(s.lineHeight)); })()")
  end

  describe "wide desktop (1920px): its own column after the amount" do
    before { visit_at(1920) }

    it "shows each note in a ملاحظات column — short in full, long clamped with the full text on hover, — when empty" do
      headers = all(".expense-list thead th").map { |th| th.text.strip.split("\n").first }
      expect(headers.index("ملاحظات")).to eq(headers.index("المبلغ") + 1)
      expect_no_overflow

      expect(row_for(without).find("td.expense-list__notes").text.strip).to eq("—")

      short_text = row_for(short).find("td.expense-list__notes .expense-list__note-text")
      expect(short_text.text).to eq(SHORT_NOTE)
      expect(short_text[:title]).to eq(SHORT_NOTE)

      expect(row_for(mixed).find("td.expense-list__notes").text).to include("1,250.75", "4587", "10/2026")

      long_text = row_for(long).find("td.expense-list__notes .expense-list__note-text")
      expect(lines(long_text)).to be <= 2
      expect(row_for(long).find("td.expense-list__notes summary")[:title]).to eq(LONG_NOTE)
      # The long note does not blow up the row height.
      expect(row_for(long).evaluate_script("this.getBoundingClientRect().height"))
        .to be <= row_for(short).evaluate_script("this.getBoundingClientRect().height") + 40

      # RTL: the note hugs the right edge of its cell and stays inside it.
      cell = row_for(short).find("td.expense-list__notes")
      geo = cell.evaluate_script(<<~JS)
        (() => { const c = this.getBoundingClientRect(), t = this.querySelector('.expense-list__note-text').getBoundingClientRect();
                 return { cr: c.right, tr: t.right, cl: c.left, tl: t.left }; })()
      JS
      expect(geo["cr"] - geo["tr"]).to be < 16
      expect(geo["tl"]).to be >= geo["cl"]
      screenshot("expenses_notes_1920", 1920)
    end

    it "expands a long note in place with عرض المزيد and collapses it again" do
      within(row_for(long).find("td.expense-list__notes")) do
        expect(page).to have_text(I18n.t("finance.expenses.note_more", locale: :ar))
        find("summary").click
        expect(lines(find(".expense-list__note-text"))).to be > 2
        expect(page).to have_text(I18n.t("finance.expenses.note_less", locale: :ar))
        find("summary").click
        expect(lines(find(".expense-list__note-text"))).to be <= 2
      end
      expect_no_overflow
    end
  end

  describe "1440px desktop (list ≈976px beside the sidebars)" do
    it "folds the note under the amount instead of squeezing other columns" do
      visit_at(1440)
      expect_no_overflow
      expect(page).to have_no_css("th.expense-list__notes-th")
      expect(page).to have_no_css("td.expense-list__notes")

      expect(row_for(short).find(".expense-list__amount-note")).to have_text(SHORT_NOTE)
      expect(row_for(without)).to have_no_css(".expense-list__amount-note")
      expect(lines(row_for(long).find(".expense-list__amount-note .expense-list__note-text"))).to be <= 2
      expect(row_for(long).find(".expense-list__amount-note summary")[:title]).to eq(LONG_NOTE)
      screenshot("expenses_notes_1440", 1440)
    end
  end

  it "English at 1920px: the wider English columns leave no room, so the note folds under the amount" do
    owner.update!(preferred_locale: "en")
    sign_in owner
    emulate(1920)
    visit finance_expenses_path
    expect(page).to have_css("html[dir='ltr']")
    expect_no_overflow
    expect(page).to have_no_css("td.expense-list__notes")
    expect(row_for(short).find(".expense-list__amount-note")).to have_text(SHORT_NOTE)
  end

  describe "mobile (390px): a ملاحظات section in the card" do
    before { visit_at(390) }

    it "shows the section only when there is a note, readable, inside the card" do
      expect(js("getComputedStyle(document.querySelector('.expense-list__row')).display")).to eq("grid")
      expect_no_overflow

      expect(row_for(without)).to have_no_css("td.expense-list__notes")

      section = row_for(short).find("td.expense-list__notes")
      expect(section).to have_css(".expense-list__notes-label", text: I18n.t("finance.common.notes", locale: :ar))
      expect(section).to have_text(SHORT_NOTE)
      expect(row_for(mixed).find("td.expense-list__notes")).to have_text(MIXED_NOTE)

      card = row_for(long)
      text = card.find("td.expense-list__notes .expense-list__note-text")
      expect(lines(text)).to be <= 3
      inside = card.evaluate_script(<<~JS)
        (() => { const c = this.getBoundingClientRect(), t = this.querySelector('.expense-list__notes').getBoundingClientRect();
                 return t.left >= c.left - 1 && t.right <= c.right + 1; })()
      JS
      expect(inside).to be(true)

      card.find("td.expense-list__notes summary").click
      expect(lines(text)).to be > 3
      expect_no_overflow
      screenshot("expenses_notes_390", 390)
    end
  end
end
