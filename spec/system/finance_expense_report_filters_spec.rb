require "rails_helper"

# Browser coverage for the Expenses by Type / by Category filter bar: custom
# dates appear only for the custom period, Apply keeps the chosen filters,
# Reset returns to the default, and the bar lays out in AR (RTL) / EN on
# desktop and phone.
#
# Set SCREENSHOT_DIR=/some/dir to also save a screenshot per report/locale/width.
RSpec.describe "Finance expense report filters", type: :system do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:north)   { create(:branch, business: business, name: "مدينة نصر") }
  let!(:south)   { create(:branch, business: business, name: "Uptown") }
  let(:rent)     { create(:expense_category, business: business, name: "إيجار") }

  before do
    create(:expense, :approved, business: business, branch: north, expense_category: rent, amount: 1000,
                                expense_date: BusinessDay.current(context: business))
  end

  def set_viewport(width, height = 900)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: width, height: height, deviceScaleFactor: 1, mobile: width < 768)
  end

  def no_horizontal_scroll!
    expect(page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")).to be <= 0
  end

  def screenshot(name)
    return unless ENV["SCREENSHOT_DIR"]

    set_viewport(page.evaluate_script("window.innerWidth"), [ page.evaluate_script("document.documentElement.scrollHeight"), 900 ].max)
    page.save_screenshot(File.join(ENV["SCREENSHOT_DIR"], "#{name}.png"))
  end

  it "shows custom dates only for a custom period, and Apply / Reset keep or clear the filters" do
    sign_in owner
    visit finance_expenses_by_category_report_path

    expect(page).to have_no_field("from")
    select I18n.t("finance.reports.expense_filters.presets.custom"), from: "period"
    expect(page).to have_field("from")
    select I18n.t("finance.reports.expense_filters.presets.current_month"), from: "period"
    expect(page).to have_no_field("from")

    select "Uptown", from: "branch_id"
    click_button I18n.t("finance.reports.expense_filters.apply")

    expect(page).to have_select("period", selected: I18n.t("finance.reports.expense_filters.presets.current_month"))
    expect(page).to have_select("branch_id", selected: "Uptown")
    expect(page).to have_text(I18n.t("finance.reports.no_data"))
    expect(find_link(I18n.t("finance.reports.export_csv"))[:href]).to include("branch_id=#{south.id}", "period=current_month")

    click_link I18n.t("finance.reports.expense_filters.reset")
    expect(page).to have_select("period", selected: I18n.t("finance.reports.expense_filters.presets.last_6_months"))
    expect(page).to have_select("branch_id", selected: I18n.t("finance.reports.expense_filters.all_branches"))
  end

  %w[ar en].each do |locale|
    [ 1280, 375 ].each do |width|
      it "lays out both reports' filter bars at #{width}px (#{locale})" do
        owner.update!(preferred_locale: locale)
        set_viewport(width)
        sign_in owner

        { "category" => finance_expenses_by_category_report_path(period: "custom", from: "2026-01-01", to: "2026-12-31", branch_id: north.id),
          "type"     => finance_expenses_by_type_report_path(period: "custom", from: "2026-01-01", to: "2026-12-31", branch_id: north.id) }
          .each do |name, url|
            visit url
            expect(page.evaluate_script("document.documentElement.dir")).to eq(locale == "ar" ? "rtl" : "ltr")
            expect(page).to have_field("from", with: "2026-01-01")
            expect(page).to have_select("branch_id", selected: "مدينة نصر")
            expect(page).to have_button(I18n.t("finance.reports.expense_filters.apply", locale: locale))
            expect(page).to have_link(I18n.t("finance.reports.expense_filters.reset", locale: locale))
            no_horizontal_scroll!
            screenshot("expense-report-#{name}-#{locale}-#{width}")
          end
      end
    end
  end
end
