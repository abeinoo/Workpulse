require "rails_helper"

# Browser coverage for the Employee Obligations index: the collapsible filter
# panel (bottom sheet on phones), URL-backed search/filter/sort state incl.
# back/forward, and no horizontal page overflow at desktop and phone widths
# in both Arabic (RTL) and English (LTR).
#
# Set SCREENSHOT_DIR=/some/dir to also save a full-height screenshot per
# width/locale for visual review.
RSpec.describe "Admin::EmployeeObligations index", type: :system do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business, preferred_locale: "en") }
  let(:olaya)    { create(:branch, business: business, name: "Olaya") }
  let(:malqa)    { create(:branch, business: business, name: "Al Malqa") }

  let!(:employees) do
    [
      %w[Sara Nasser], %w[Omar Haddad], %w[Layla Al-Qahtani],
      %w[Yousef Rahman], %w[Noura Al-Fahad], %w[Khalid Mansour]
    ].map.with_index do |(first, last), i|
      create(:user, business: business, first_name: first, last_name: last, employee_code: "E-#{100 + i}").tap do |u|
        create(:shift_assignment, business: business, user: u, branch: i.even? ? olaya : malqa)
      end
    end
  end

  before do
    types    = EmployeeObligation::OBLIGATION_TYPES
    statuses = %w[active active active paused completed cancelled]
    30.times do |i|
      status    = statuses[i % statuses.size]
      total     = 600.0 + (i * 150)
      remaining = status == "completed" ? 0.0 : (total / 2).round
      create(:employee_obligation,
             user: employees[i % employees.size], business: business, created_by: owner,
             obligation_type: types[i % types.size], status: status,
             title: "#{%w[Laptop Phone Uniform Advance Penalty][i % 5]} installment #{i + 1}",
             start_month: (i % 12) + 1, start_year: 2026,
             total_amount: total, remaining_amount: remaining, installment_amount: 300.0)
    end
    sign_in owner
  end

  def set_viewport(width, height = 900)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: width, height: height, deviceScaleFactor: 1, mobile: width < 768)
  end

  def horizontal_overflow
    page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
  end

  def screenshot(name)
    return unless ENV["SCREENSHOT_DIR"]

    full_height = page.evaluate_script("document.documentElement.scrollHeight")
    width       = page.evaluate_script("window.innerWidth")
    set_viewport(width, [ full_height, 900 ].max)
    page.save_screenshot(File.join(ENV["SCREENSHOT_DIR"], "#{name}.png"))
    set_viewport(width)
  end

  describe "layout" do
    %w[ar en].each do |locale|
      [ 1440, 1280, 1024, 430, 390, 375 ].each do |width|
        it "has no horizontal overflow at #{width}px (#{locale})" do
          owner.update!(preferred_locale: locale)
          set_viewport(width)
          visit admin_employee_obligations_path(status: "active")

          expect(page).to have_css(".obl-table tbody tr", minimum: 1)
          expect(page.evaluate_script("document.documentElement.dir")).to eq(locale == "ar" ? "rtl" : "ltr")
          expect(horizontal_overflow).to be <= 0
          # html clips overflow-x, so also check the rows themselves fit.
          row_right = page.evaluate_script("Math.max(...[...document.querySelectorAll('.obl-table tbody tr')].map(r => r.getBoundingClientRect().right))")
          row_left  = page.evaluate_script("Math.min(...[...document.querySelectorAll('.obl-table tbody tr')].map(r => r.getBoundingClientRect().left))")
          expect(row_left).to be >= 0
          expect(row_right).to be <= width if width < 769
          # Desktop: all columns fit without scrolling the table sideways.
          if width >= 1024
            expect(page.evaluate_script("(w => w.scrollWidth - w.clientWidth)(document.querySelector('.obl-table'))")).to be <= 0
          end
          screenshot("obligations-#{locale}-#{width}")

          # Summary reflects the filtered set (status=active → 15 of 30).
          expect(first(".obl-summary .stat-card__value")).to have_text("15")

          find(".obl-toolbar__filters").click
          expect(page).to have_css("#obl-filter-panel", visible: true)
          month_labels = locale == "ar" ? [ "من شهر", "إلى شهر" ] : [ "Start month", "End month" ]
          # filter-bar__label is text-transform: uppercase, so compare case-insensitively.
          expect(find("label[for='start_from']").text.downcase).to eq(month_labels[0].downcase)
          expect(find("label[for='start_to']").text.downcase).to eq(month_labels[1].downcase)
          expect(page).to have_select("start_from", with_options: [ locale == "ar" ? "يناير 2026" : "January 2026" ])
          expect(horizontal_overflow).to be <= 0
          screenshot("obligations-#{locale}-#{width}-filters") if [ 1440, 390 ].include?(width)
        end
      end
    end
  end

  it "applies filters from the panel, reflects them in the URL, and supports back/forward" do
    set_viewport(1280)
    visit admin_employee_obligations_path

    expect(page).to have_css(".obl-table tbody tr", count: 20)
    expect(page).to have_css(".pagination")

    find(".obl-toolbar__filters").click
    within("#obl-filter-panel") do
      select "Active", from: "status"
      select "Has remaining balance", from: "balance"
      click_button "Apply Filters"
    end

    expect(page).to have_current_path(/status=active/)
    expect(page).to have_current_path(/balance=outstanding/)
    expect(find(".obl-toolbar__filters .attn-filter-count")).to have_text("2")
    expect(page).to have_css(".filter-chip", text: "Status: Active")
    expect(all(".obl-table tbody .badge").map { |b| b.text.downcase }.uniq).to eq([ "active" ])

    fill_in "q", with: "Sara"
    find("#q").send_keys(:enter)
    expect(page).to have_current_path(/q=Sara/)
    expect(page).to have_current_path(/status=active/)
    expect(all(".obl-table tbody .employee-cell__name").map(&:text).uniq).to eq([ "Sara Nasser" ])

    page.go_back
    expect(page).not_to have_current_path(/q=Sara/)
    expect(page).to have_current_path(/status=active/)
    page.go_forward
    expect(page).to have_current_path(/q=Sara/)

    click_link "Reset Filters", match: :first
    expect(page).to have_current_path(admin_employee_obligations_path)
    expect(page).not_to have_css(".filter-chip")
  end

  it "sorts via column headers, keeps sort across pages, and returns to the filtered list from a detail page" do
    set_viewport(1280)
    visit admin_employee_obligations_path(status: "active")

    within(".obl-table thead") { click_link "Remaining" }
    expect(page).to have_current_path(/sort=remaining/)
    expect(page).to have_current_path(/dir=desc/)
    amounts = all(".obl-table tbody td.obl-desktop-cell .obl-remaining").map { |n| n.text.gsub(/[^\d.]/, "").to_f }
    expect(amounts).to eq(amounts.sort.reverse)

    first(".obl-table tbody tr td.td-secondary", text: /Cash Loan|Equipment|Penalty|Custom/).click
    expect(page).to have_current_path(%r{/admin/employee_obligations/\d+\z})

    find("a.back-link").click
    expect(page).to have_current_path(/status=active/)
  end

  it "uses a bottom-sheet filter panel on phones that can be closed" do
    set_viewport(390)
    visit admin_employee_obligations_path

    find(".obl-toolbar__filters").click
    panel = find("#obl-filter-panel", visible: true)
    expect(page.evaluate_script("getComputedStyle(document.getElementById('obl-filter-panel')).position")).to eq("fixed")
    within(panel) { find("button[aria-label='Close']").click }
    expect(page).to have_css("#obl-filter-panel", visible: :hidden)

    # Employee name and remaining balance are both visible on each card.
    card = first(".obl-table tbody tr")
    expect(card).to have_css(".employee-cell__name", visible: true)
    expect(card).to have_css(".obl-cell-employee__remaining .obl-remaining", visible: true)

    # Mobile sort control
    select "Remaining", from: "sort"
    expect(page).to have_current_path(/sort=remaining/)
  end

  it "updates the summary cards when filters are applied, and keeps them across pages" do
    set_viewport(1280)
    visit admin_employee_obligations_path
    expect(all(".obl-summary .stat-card__value").first(3).map(&:text)).to eq(%w[30 15 5])

    find(".obl-toolbar__filters").click
    within("#obl-filter-panel") do
      select "January 2026", from: "start_from"
      select "March 2026",   from: "start_to"
      click_button "Apply Filters"
    end
    expect(page).to have_current_path(/start_from=2026-01/)
    expect(page).to have_css(".filter-chip", text: "Start month: January 2026")
    # Start months cycle Jan..Dec over 30 rows → Jan, Feb, Mar hold 3 each.
    expect(all(".obl-summary .stat-card__value").first.text).to eq("9")
    expect(page).to have_css(".obl-table tbody tr", count: 9)

    visit admin_employee_obligations_path(sort: "total", dir: "asc", page: 2)
    expect(all(".obl-summary .stat-card__value").first(3).map(&:text)).to eq(%w[30 15 5])
  end

  it "shows the no-results state with a reset action" do
    set_viewport(1280)
    visit admin_employee_obligations_path(q: "zzz-nothing")

    expect(page).to have_text("No results match the filters")
    within(".empty-state") { click_link "Reset Filters" }
    expect(page).to have_css(".obl-table tbody tr", count: 20)
  end
end
