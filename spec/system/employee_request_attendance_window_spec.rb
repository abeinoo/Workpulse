require "rails_helper"

# Browser coverage for cross-day punch-correction protection: employee form
# warning, reviewer warning + confirmation, and legitimate overnight requests.
#
# Set SCREENSHOT_DIR=/some/dir to also save full-page screenshots.
RSpec.describe "Employee request attendance window", type: :system do
  let(:business) { create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 0) }
  let(:branch)   { create(:branch, business: business) }
  let(:employee) { create(:user, business: business, first_name: "Sara", last_name: "Nasser", preferred_locale: "ar") }
  let(:manager) do
    role = create(:permission_role, business: business, permissions: %w[view_requests approve_requests])
    create(:user, business: business, permission_role: role, first_name: "Mahmoud", last_name: "Hosny",
                  preferred_locale: "ar")
  end
  let(:riyadh)    { ActiveSupport::TimeZone["Asia/Riyadh"] }
  let(:work_date) { Date.new(2026, 9, 13) }

  def at(day, hour, min = 0) = riyadh.local(2026, 9, day, hour, min)

  let!(:record) do
    shift = Time.use_zone(business.timezone) do
      create(:shift, :fixed_time, business: business, name: "Evening", start_time: "19:00", end_time: "02:00")
    end
    assignment = create(:shift_assignment, user: employee, branch: branch, shift: shift,
                        effective_from: Date.new(2026, 1, 1))
    branch.update_column(:branch_manager_id, manager.id)
    create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment,
           date: work_date, work_date: work_date,
           check_in_at: at(13, 19, 5), check_out_at: at(14, 0, 3), status: "present", worked_minutes: 298)
  end

  def set_viewport(width, height = 900)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                    width: width, height: height, deviceScaleFactor: 1, mobile: width < 768)
  end

  # Flatpickr keeps the machine value on the real input; set it through the picker.
  def set_picker(id, value)
    page.execute_script(<<~JS, id, value)
      const [id, v] = arguments; const el = document.getElementById(id);
      el._flatpickr ? el._flatpickr.setDate(v, true) : (el.value = v);
    JS
  end

  def fill_correction(type:, proposed_date:, proposed_time:)
    find("#request_type_select").select(I18n.t("requests.types.punch_correction", locale: :ar))
    find("#employee_request_correction_type").select(I18n.t("requests.correction_types.#{type}", locale: :ar))
    set_picker("employee_request_requested_for_date", work_date.iso8601)
    set_picker("employee_request_proposed_date", proposed_date)
    set_picker("employee_request_proposed_time", proposed_time)
    fill_in "employee_request[reason]", with: "نسيت البصمة"
  end

  def screenshot(name)
    return unless ENV["SCREENSHOT_DIR"]

    width = page.evaluate_script("window.innerWidth")
    set_viewport(width, [ page.evaluate_script("document.documentElement.scrollHeight"), 900 ].max)
    page.save_screenshot(File.join(ENV["SCREENSHOT_DIR"], "#{name}.png"))
    set_viewport(width)
  end

  def no_horizontal_overflow!
    expect(page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")).to be <= 0
  end

  describe "employee form" do
    before { sign_in employee }

    it "submits a normal overnight request (check-out after midnight) without a warning" do
      visit new_employee_request_path
      fill_correction(type: "wrong_check_out_time", proposed_date: "2026-09-14", proposed_time: "01:30")
      click_button I18n.t("requests.new.submit", locale: :ar)

      expect(page).to have_current_path(employee_requests_path)
      expect(page).to have_no_css("[data-testid='window-warning']")
      expect(EmployeeRequest.last).to have_attributes(proposed_date: Date.new(2026, 9, 14), proposed_time: "01:30")
    end

    it "warns about an out-of-window request and saves it only after acknowledgement" do
      set_viewport(375)
      visit new_employee_request_path
      fill_correction(type: "wrong_check_in_time", proposed_date: "2026-09-12", proposed_time: "15:10")
      click_button I18n.t("requests.new.submit", locale: :ar)

      warning = find("[data-testid='window-warning']")
      expect(warning).to have_text("تنبيه: الوقت المقترح خارج نطاق يوم العمل")
      expect(warning).to have_text("13 سبتمبر 2026")
      expect(warning).to have_text("12 سبتمبر 2026 — 03:10 PM")
      expect(EmployeeRequest.count).to eq(0)
      expect(find("#employee_request_proposed_date", visible: :all).value).to eq("2026-09-12") # not altered
      no_horizontal_overflow!
      screenshot("window-employee-warning-ar-375")

      find("input[name='employee_request[acknowledge_out_of_window]']").check
      click_button I18n.t("requests.new.submit", locale: :ar)

      expect(page).to have_current_path(employee_requests_path)
      expect(EmployeeRequest.last).to have_attributes(proposed_date: Date.new(2026, 9, 12), proposed_time: "15:10")
    end
  end

  describe "reviewer" do
    before { sign_in manager }

    it "sees the warning and must explicitly confirm before approval" do
      bad = create(:employee_request, :punch_correction, user: employee, correction_type: "wrong_check_in_time",
                   requested_for_date: work_date, proposed_date: Date.new(2026, 9, 12), proposed_time: "15:10")
      set_viewport(1280)
      visit employee_request_path(bad)

      alert = find("[data-testid='window-alert']")
      expect(alert).to have_text("هذا التعديل خارج نطاق الشيفت المتوقع وقد يؤثر على مدة العمل.")
      expect(alert).to have_text("الوقت المقترح خارج نطاق يوم العمل")
      expect(find("[data-testid='resulting-duration']")).to have_text("مدة العمل بعد التعديل").and have_text("32 ساعة و53 دقيقة")
      expect(find("[data-testid='resulting-duration-warning']")).to have_text("🔴 مدة عمل غير طبيعية").and have_text("هذه المدة تتجاوز 24 ساعة وتتطلب مراجعة.")
      expect(find("[data-testid='window-status']")).to have_text("خارج نطاق يوم العمل")
      expect(find("[data-testid='window-work-date']")).to have_text("13 سبتمبر 2026")
      expect(find("[data-testid='window-final']")).to have_text("12 سبتمبر 2026 — 03:10 PM")
      no_horizontal_overflow!
      screenshot("window-reviewer-ar-1280")

      # Approve without ticking: the browser blocks submission (required checkbox).
      click_button I18n.t("requests.approve", locale: :ar)
      expect(page).to have_current_path(employee_request_path(bad))
      expect(bad.reload).to be_pending

      find("input[name='confirm_out_of_window']").check
      click_button I18n.t("requests.approve", locale: :ar)

      expect(page).to have_css("[data-testid='duration-alert']", text: "مدة عمل غير طبيعية: 32 ساعة و53 دقيقة")
      expect(bad.reload).to be_approved
      expect(record.reload.check_in_at).to eq(at(12, 15, 10))
      screenshot("window-reviewer-approved-ar-1280")
    end

    it "shows the resulting duration and its critical warning above the Approve button on a phone (Arabic)" do
      bad = create(:employee_request, :punch_correction, user: employee, correction_type: "wrong_check_in_time",
                   requested_for_date: work_date, proposed_date: Date.new(2026, 9, 12), proposed_time: "15:10")
      set_viewport(375)
      visit employee_request_path(bad)

      expect(find("[data-testid='resulting-duration-value']")).to have_text("32 ساعة و53 دقيقة")
      expect(find("[data-testid='resulting-duration-warning']")).to have_text("هذه المدة تتجاوز 24 ساعة وتتطلب مراجعة.")
      expect(find("[data-testid='window-alert']")).to have_text("الوقت المقترح خارج نطاق يوم العمل")
      card_top    = page.evaluate_script("document.querySelector('[data-testid=resulting-duration]').getBoundingClientRect().top")
      approve_top = page.evaluate_script("document.querySelector('form[action$=\"/approve\"] input[type=submit]').getBoundingClientRect().top")
      expect(card_top).to be < approve_top
      no_horizontal_overflow!
      screenshot("resulting-duration-ar-375")
    end

    it "edits the final date in the review form; nothing is shifted automatically (Arabic)" do
      # After-midnight check-out entered with the work date: literally before the check-in.
      # Submitted before the check-out ordering rule existed (refused at creation today).
      req = create(:employee_request, :punch_correction, :predating_check_out_order_rule,
                   user: employee, correction_type: "wrong_check_out_time",
                   requested_for_date: work_date, proposed_date: work_date, proposed_time: "01:30")
      set_viewport(375)
      visit employee_request_path(req)

      expect(find("[data-testid='review-correction-type']")).to have_text("نوع التعديل")
      expect(page).to have_css("[data-testid='punch-order-invalid']")
      no_horizontal_overflow!
      screenshot("review-datetime-ar-375")

      # Reviewer moves the date to another work day (15 Sep): the page comes back
      # with the checks re-run on those values and asks for confirmation.
      set_picker("approved_at", "2026-09-15T01:30")
      click_button I18n.t("requests.approve", locale: :ar)
      expect(page).to have_css("[data-testid='window-confirm']")
      expect(find("[data-testid='window-final']")).to have_text("15 سبتمبر 2026 — 01:30 AM")
      expect(req.reload).to be_pending

      # Corrects it to the real next-day date — in-window, approved as selected.
      set_picker("approved_at", "2026-09-14T01:30")
      find("input[name='confirm_out_of_window']").check
      click_button I18n.t("requests.approve", locale: :ar)

      expect(page).to have_text(I18n.t("flash.request_approved", locale: :ar))
      expect(req.reload).to have_attributes(status: "approved", proposed_date: work_date, approved_punch_at: at(14, 1, 30))
      expect(record.reload.check_out_at).to eq(at(14, 1, 30))
      screenshot("review-datetime-approved-ar-375")
    end

    it "blocks a check-out equal to the check-in in the browser, with the Arabic message" do
      req = create(:employee_request, :punch_correction, user: employee, correction_type: "wrong_check_out_time",
                   requested_for_date: work_date, proposed_date: Date.new(2026, 9, 14), proposed_time: "01:30")
      visit employee_request_path(req)
      expect(page).to have_no_css("[data-testid='punch-order-client-error']")

      set_picker("approved_at", "2026-09-13T19:05") # exactly the check-in
      click_button I18n.t("requests.approve", locale: :ar)

      expect(find("[data-testid='punch-order-client-error']")).to have_text("وقت الانصراف يجب أن يكون بعد وقت الحضور.")
      expect(page).to have_current_path(employee_request_path(req))
      expect(req.reload).to be_pending
      expect(record.reload.check_out_at).to eq(at(14, 0, 3))
    end

    it "approves a legitimate overnight correction with no warning or confirmation (English LTR)" do
      manager.update!(preferred_locale: "en")
      ok = create(:employee_request, :punch_correction, user: employee, correction_type: "wrong_check_out_time",
                  requested_for_date: work_date, proposed_date: Date.new(2026, 9, 14), proposed_time: "01:30")
      set_viewport(375)
      visit employee_request_path(ok)

      expect(page.evaluate_script("document.documentElement.dir")).to eq("ltr")
      expect(page).to have_no_css("[data-testid='window-alert']")
      expect(page).to have_no_css("[data-testid='window-confirm']")
      expect(find("[data-testid='window-status']")).to have_text(/inside the work-day window/i)
      expect(find("[data-testid='window-final']")).to have_text("Sep 14, 2026 — 01:30 AM")
      expect(find("[data-testid='resulting-duration-value']")).to have_text("6h 25m")
      expect(page).to have_no_css("[data-testid='resulting-duration-warning']")
      no_horizontal_overflow!
      screenshot("window-reviewer-ok-en-375")

      click_button I18n.t("requests.approve", locale: :en)
      expect(page).to have_text(I18n.t("flash.request_approved", locale: :en))
      expect(ok.reload).to be_approved
      expect(page).to have_no_css("[data-testid='duration-alert']")
      expect(record.reload.worked_minutes).to eq(385)
    end
  end
end
