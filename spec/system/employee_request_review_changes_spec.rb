require "rails_helper"

# Browser coverage for the punch-correction detail page: the "Reviewer Changes"
# section reads original → reviewed in the text direction (RTL and LTR), and
# 12-hour clocks keep "03:10 PM" visual order inside Arabic text.
#
# Set SCREENSHOT_DIR=/some/dir to also save a screenshot per width/locale.
RSpec.describe "Employee request reviewer changes", type: :system do
  let(:business) { create(:business, timezone: "Asia/Riyadh") }
  let(:branch)   { create(:branch, business: business) }
  let(:employee) { create(:user, business: business, first_name: "Sara", last_name: "Nasser") }
  let(:manager) do
    role = create(:permission_role, business: business, permissions: %w[view_requests approve_requests])
    create(:user, business: business, permission_role: role, first_name: "Mahmoud", last_name: "Hosny")
  end
  let(:riyadh)    { ActiveSupport::TimeZone["Asia/Riyadh"] }
  let(:work_date) { Date.new(2026, 9, 14) }

  let!(:request) do
    create(:attendance_record, user: employee, branch: branch, date: work_date, work_date: work_date,
           check_in_at: riyadh.local(2026, 9, 14, 9, 30), check_out_at: riyadh.local(2026, 9, 14, 14, 5),
           status: "present", worked_minutes: 275)
    branch.update_column(:branch_manager_id, manager.id)
    req = create(:employee_request, :punch_correction, user: employee, correction_type: "wrong_check_in_time",
                 requested_for_date: work_date, proposed_time: "15:10")
    travel_to(Time.utc(2026, 9, 14, 19, 8)) do
      expect(Requests::Approver.approve(request: req, reviewed_by: manager, approved_time: "02:07")).to be_success
    end
    req
  end

  def set_viewport(width, height = 900)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: width, height: height, deviceScaleFactor: 1, mobile: width < 768)
  end

  def rect(selector)
    page.evaluate_script("(r => ({ left: r.left, right: r.right, top: r.top }))(document.querySelector(#{selector.to_json}).getBoundingClientRect())")
  end

  # Visual x-position of a substring inside the first element matching selector.
  def substring_left(selector, needle)
    page.evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector(#{selector.to_json});
        const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
        let node;
        while ((node = walker.nextNode())) {
          const i = node.textContent.indexOf(#{needle.to_json});
          if (i >= 0) {
            const r = document.createRange();
            r.setStart(node, i); r.setEnd(node, i + #{needle.length});
            return r.getBoundingClientRect().left;
          }
        }
        return null;
      })()
    JS
  end

  %w[ar en].each do |locale|
    [ 1280, 375 ].each do |width|
      it "renders the reviewer change readably at #{width}px (#{locale})" do
        manager.update!(preferred_locale: locale)
        sign_in manager
        set_viewport(width)
        visit employee_request_path(request)

        section = "[data-testid='reviewer-change-check_in']"
        expect(page).to have_css(section)
        expect(page.evaluate_script("document.documentElement.dir")).to eq(locale == "ar" ? "rtl" : "ltr")
        expect(find("#{section} .review-change__old")).to have_text("03:10 PM")
        expect(find("#{section} .review-change__new")).to have_text("02:07 AM")

        old_box = rect("#{section} .review-change__old")
        new_box = rect("#{section} .review-change__new")
        # Date + time values can wrap on phones: then the reviewed value sits on
        # the next line; on one line it follows the original in text direction.
        wrapped = new_box["top"] > old_box["top"] + 1
        arrow_transform = page.evaluate_script(
          "getComputedStyle(document.querySelector(#{"#{section} .review-change__arrow".to_json})).transform"
        )
        if locale == "ar"
          # RTL: original sits at the start (right), reviewed value at the end (left), arrow mirrored.
          expect(wrapped || old_box["left"] > new_box["left"]).to be true
          expect(arrow_transform).to start_with("matrix(-1")
        else
          expect(wrapped || old_box["left"] < new_box["left"]).to be true
          expect(arrow_transform).to eq("none")
        end

        # The clock keeps "HH:MM PM" visual order even inside RTL text.
        expect(substring_left("#{section} .review-change__old", "03:10"))
          .to be < substring_left("#{section} .review-change__old", "PM")

        within("[data-testid='reviewer-changes']") do
          expect(page).to have_text("Mahmoud Hosny")
          expect(page).to have_text(locale == "ar" ? "14 سبتمبر 2026 10:08 PM" : "Sep 14, 2026 10:08 PM")
        end
        expect(page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")).to be <= 0

        if ENV["SCREENSHOT_DIR"]
          set_viewport(width, [ page.evaluate_script("document.documentElement.scrollHeight"), 900 ].max)
          page.save_screenshot(File.join(ENV["SCREENSHOT_DIR"], "review-changes-#{locale}-#{width}.png"))
        end
      end
    end
  end
end
