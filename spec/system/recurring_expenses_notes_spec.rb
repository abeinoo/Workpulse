require "rails_helper"

# Browser coverage for recurring expense notes: the notes textarea on the form,
# the clamped notes column on the index (expandable by keyboard, blank notes
# leave no empty row on phones) and the card layout of the show page — in
# AR (RTL) / EN, desktop / phone.
#
# Set SCREENSHOT_DIR=/some/dir to also save a screenshot per page/locale/width.
RSpec.describe "Recurring expense notes", type: :system do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:branch_a) { create(:branch, business: business, name: "مدينة نصر") }
  let(:branch_b) { create(:branch, business: business, name: "Uptown") }
  let(:category) { create(:expense_category, business: business, name: "إيجار") }
  let(:long_note) { "يُدفع الإيجار للمالك بتحويل بنكي قبل اليوم الخامس من كل شهر، ويُرفق إيصال التحويل. " * 3 }

  let!(:with_long_note) do
    create(:recurring_expense, business: business, expense_category: category, amount: 4500, notes: long_note).tap do |rec|
      rec.recurring_expense_allocations.create!(branch: branch_a, allocation_percentage: 60)
      rec.recurring_expense_allocations.create!(branch: branch_b, allocation_percentage: 40)
    end
  end
  let!(:without_note) do
    create(:recurring_expense, business: business, expense_category: category, branch: branch_a, amount: 300,
                               next_run_on: Date.current + 1)
  end

  def set_viewport(width, height = 900)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: width, height: height, deviceScaleFactor: 1, mobile: width < 768)
  end

  def rect(selector)
    page.evaluate_script("(r => ({ left: r.left, right: r.right, top: r.top, width: r.width, height: r.height }))" \
                         "(document.querySelector(#{selector.to_json}).getBoundingClientRect())").symbolize_keys
  end

  def no_horizontal_scroll!
    expect(page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")).to be <= 0
  end

  def screenshot(name)
    return unless ENV["SCREENSHOT_DIR"]

    set_viewport(page.evaluate_script("window.innerWidth"), [ page.evaluate_script("document.documentElement.scrollHeight"), 900 ].max)
    page.save_screenshot(File.join(ENV["SCREENSHOT_DIR"], "#{name}.png"))
  end

  def notes_cell(record)
    "tr:has(a[href='#{finance_recurring_expense_path(record)}']) td.expense-list__notes"
  end

  it "expands a long note on the index with the keyboard" do
    sign_in owner
    visit finance_recurring_expenses_path

    summary = find("#{notes_cell(with_long_note)} details.expense-list__note > summary")
    expect(page).to have_no_css("#{notes_cell(with_long_note)} details[open]")

    summary.send_keys(:enter)
    expect(page).to have_css("#{notes_cell(with_long_note)} details[open]")
    expect(page).to have_css("#{notes_cell(with_long_note)} .expense-list__note-toggle[aria-hidden='true']", visible: :all)
  end

  %w[ar en].each do |locale|
    [ 1280, 375 ].each do |width|
      it "lays out the form, index and show page at #{width}px (#{locale})" do
        owner.update!(preferred_locale: locale)
        set_viewport(width)
        sign_in owner

        # ── Form: notes textarea after the details, before the branch distribution ──
        visit edit_finance_recurring_expense_path(with_long_note)
        expect(page.evaluate_script("document.documentElement.dir")).to eq(locale == "ar" ? "rtl" : "ltr")
        expect(find_field("recurring_expense[notes]").value).to eq(long_note)
        expect(page).to have_css("label[for='recurring_expense_notes']", text: locale == "ar" ? "الملحوظات" : "Notes")
        notes_top   = rect("#recurring_expense_notes")[:top]
        expect(notes_top).to be > rect("#recurring_expense_active")[:top]
        expect(notes_top).to be < rect("[data-line-items-target='rows']")[:top]
        no_horizontal_scroll!
        screenshot("recurring-form-#{locale}-#{width}")

        # ── Index ──
        visit finance_recurring_expenses_path
        expect(page).to have_css("#{notes_cell(with_long_note)} .expense-list__note-text")
        no_horizontal_scroll!
        if width < 768
          row  = rect("tr:has(a[href='#{finance_recurring_expense_path(with_long_note)}'])")
          cell = rect(notes_cell(with_long_note))
          # The notes row spans the card like every other label/value row.
          expect(cell[:width]).to be >= row[:width] - 40
          # A blank note leaves no empty labelled row in the card.
          expect(page).to have_no_css(notes_cell(without_note))
        else
          # Never widens the table. max-width on a table cell is only a hint to the
          # browser, so allow a little over the 180px cap; a long note left unclamped
          # would stretch the column far wider than this.
          expect(rect(notes_cell(with_long_note))[:width]).to be <= 240
          # Clamped to two lines until expanded.
          expect(rect("#{notes_cell(with_long_note)} .expense-list__note-text")[:height]).to be < 60
        end
        screenshot("recurring-index-#{locale}-#{width}")

        # ── Show ──
        visit finance_recurring_expense_path(with_long_note)
        expect(page).to have_css(".card-title", text: locale == "ar" ? "الملحوظات" : "Notes")
        expect(page).to have_css(".card-title", text: locale == "ar" ? "الجدولة" : "Schedule")
        expect(page).to have_text("60.00%")
        expect(page).to have_css("form[action='#{generate_finance_recurring_expense_path(with_long_note)}'] [data-turbo-confirm]")
        expect(page).to have_css("form[action='#{finance_recurring_expense_path(with_long_note)}'] [data-turbo-confirm]")
        no_horizontal_scroll!
        screenshot("recurring-show-#{locale}-#{width}")
      end
    end
  end
end
