require "rails_helper"

# Browser coverage for the birthday celebration: the dialog opens with confetti,
# is acknowledged so a reload the same business day doesn't replay it, and the
# celebration + manager strip lay out cleanly in AR (RTL) / EN, desktop / phone,
# light / dark.
#
# Set SCREENSHOT_DIR=/some/dir to also save a screenshot per locale/width/theme.
RSpec.describe "Dashboard birthday celebration", type: :system do
  let(:business) { create(:business, timezone: "Asia/Riyadh") }
  let(:today)    { BusinessDay.current(context: business) }
  let(:employee) do
    create(:user, business: business, first_name: "Sara", last_name: "Nasser",
                  date_of_birth: today.change(year: 1994))
  end
  let(:manager)  { create(:user, :branch_manager, business: business, first_name: "Mona", last_name: "Saeed") }

  before do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)

    branch = Branch.find_by!(branch_manager_id: manager.id)
    branch.update!(name: "مدينة نصر")
    [ [ "Ahmed", "Mohamed" ], [ "Mohamed", "Ali" ], [ "Youssef", "Abdelrahman-Elsayed" ] ].each_with_index do |(first, last), i|
      user = create(:user, business: business, first_name: first, last_name: last,
                           date_of_birth: today.change(year: 1990 + i))
      create(:shift_assignment, business: business, user: user, branch: branch, effective_from: today - 30)
    end
  end

  def set_viewport(width, height = 900)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: width, height: height, deviceScaleFactor: 1, mobile: width < 768)
  end

  def set_theme(theme)
    page.execute_script("localStorage.setItem('theme', #{theme.to_json})")
    visit current_path
  end

  def css(selector, property)
    page.evaluate_script("getComputedStyle(document.querySelector(#{selector.to_json})).#{property}")
  end

  def no_horizontal_scroll!
    expect(page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")).to be <= 0
  end

  def screenshot(name)
    page.save_screenshot(File.join(ENV["SCREENSHOT_DIR"], "#{name}.png")) if ENV["SCREENSHOT_DIR"]
  end

  it "shows the celebration once per business day, with confetti, then stays dismissed on reload" do
    sign_in employee
    visit root_path

    expect(page).to have_css("dialog.birthday-dialog[open]")
    expect(page).to have_text("Happy Birthday, Sara!")
    expect(page).to have_css(".birthday-confetti__piece", minimum: 10, visible: :all)

    click_button "Thank you!"
    expect(page).to have_no_css("dialog.birthday-dialog[open]")
    expect(page).to have_css(".birthday-badge")

    visit root_path
    expect(page).to have_css(".birthday-badge")
    expect(page).to have_no_css("dialog.birthday-dialog", visible: :all)
  end

  it "does not show another employee's celebration to a plain employee" do
    sign_in create(:user, business: business)
    visit root_path

    expect(page).to have_no_css("dialog.birthday-dialog", visible: :all)
    expect(page).to have_no_css(".birthday-strip")
  end

  %w[ar en].each do |locale|
    [ 1280, 375 ].each do |width|
      %w[light dark].each do |theme|
        it "lays out the celebration and team strip at #{width}px (#{locale}, #{theme})" do
          employee.update!(preferred_locale: locale)
          manager.update!(preferred_locale: locale)
          set_viewport(width)

          # ── Employee dialog ──
          sign_in employee
          visit root_path
          set_theme(theme) # reload — the dialog is still eligible until acknowledged by JS
          expect(page.evaluate_script("document.documentElement.dir")).to eq(locale == "ar" ? "rtl" : "ltr")
          expect(page.evaluate_script("document.documentElement.classList.contains('dark')")).to eq(theme == "dark")

          Rails.cache.clear
          visit root_path
          expect(page).to have_css("dialog.birthday-dialog[open]")
          expect(page).to have_text(locale == "ar" ? "كل سنة وإنت طيب يا Sara!" : "Happy Birthday, Sara!")
          # Card follows the theme's surface + ink tokens (light #FFFFFF/#0F2540, dark #112240/#E8EDF4).
          expect(css(".birthday-dialog__body", "backgroundColor"))
            .to eq(theme == "dark" ? "rgb(17, 34, 64)" : "rgb(255, 255, 255)")
          expect(css(".birthday-dialog__title", "color"))
            .to eq(theme == "dark" ? "rgb(232, 237, 244)" : "rgb(15, 37, 64)")
          dialog_width = page.evaluate_script("document.querySelector('.birthday-dialog').getBoundingClientRect().width")
          expect(dialog_width).to be <= width
          # Centred (the global margin reset would otherwise pin it to a corner).
          left, right = page.evaluate_script(
            "(r => [r.left, window.innerWidth - r.right])(document.querySelector('.birthday-dialog').getBoundingClientRect())"
          )
          expect((left - right).abs).to be <= 2
          no_horizontal_scroll!
          screenshot("birthday-dialog-#{locale}-#{width}-#{theme}")

          # ── Manager strip ──
          sign_in manager
          visit root_path
          within(".birthday-strip") do
            expect(page).to have_text(locale == "ar" ? "أعياد ميلاد اليوم" : "Today's Birthdays")
            expect(page).to have_text("Ahmed Mohamed")
            expect(page).to have_text("Mohamed Ali")
            expect(page).to have_text("مدينة نصر")
          end
          expect(page).to have_no_css("dialog.birthday-dialog", visible: :all)
          no_horizontal_scroll!

          # Strip sits above the operational sections, right under the header.
          strip_top  = page.evaluate_script("document.querySelector('.birthday-strip').getBoundingClientRect().top")
          header_bot = page.evaluate_script("document.querySelector('.dashboard-header').getBoundingClientRect().bottom")
          expect(strip_top).to be >= header_bot

          if ENV["SCREENSHOT_DIR"]
            set_viewport(width, [ page.evaluate_script("document.documentElement.scrollHeight"), 900 ].max)
            screenshot("birthday-strip-#{locale}-#{width}-#{theme}")
          end
        end
      end
    end
  end
end
