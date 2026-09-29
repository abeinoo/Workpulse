require "rails_helper"

# Browser coverage for "طلب إضافة موظف": a manager submits from a phone, the
# reviewer inspects the ID photos in the full-screen viewer and approves; and
# the review page lays out cleanly in AR (RTL) / EN, desktop / phone, light / dark.
#
# Set SCREENSHOT_DIR=/some/dir to also save a screenshot per locale/width/theme.
RSpec.describe "Employee data requests", type: :system do
  let(:business) { create(:business).tap { |b| seed_job_titles(b) } }
  let(:manager)  { edr_manager(business: business, first_name: "Mona", last_name: "Saeed", preferred_locale: "ar") }
  let(:reviewer) { edr_reviewer(business: business, first_name: "Omar", last_name: "Adel", preferred_locale: "ar") }

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

  def images_loaded!(selector)
    expect(page).to have_css(selector, minimum: 1)
    loaded = page.evaluate_async_script(<<~JS, selector)
      const [sel, done] = arguments;
      const imgs = [...document.querySelectorAll(sel)];
      imgs.forEach(i => { i.loading = "eager"; i.scrollIntoView({ block: "center" }); });
      Promise.all(imgs.map(i => i.complete ? Promise.resolve() : new Promise(r => { i.onload = i.onerror = r })))
        .then(() => done(imgs.every(i => i.naturalWidth > 0)));
    JS
    expect(loaded).to be(true)
  end

  def screenshot(name)
    page.save_screenshot(File.join(ENV["SCREENSHOT_DIR"], "#{name}.png")) if ENV["SCREENSHOT_DIR"]
  end

  it "manager submits from a phone; reviewer inspects the ID photos and approves" do
    set_viewport(375)
    sign_in manager
    visit new_employee_data_request_path

    expect(page).to have_css("html[dir='rtl']")
    field_names = page.evaluate_script("[...document.querySelectorAll('form.edr-form [name]')].map(e => e.name)")
    expect(field_names).to include("employee_data_request[full_name]", "employee_data_request[id_front]")
    expect(field_names.grep(/branch|salary|permission|shift|commission|payroll/)).to be_empty
    fill_in "الاسم بالكامل", with: "محمد أحمد علي حسن"
    fill_in "الرقم القومي", with: "29501011234567"
    fill_in "رقم الهاتف", with: "01001234567"
    fill_in "العنوان", with: "15 شارع التحرير، الدقي، الجيزة"
    page.execute_script("document.querySelector('#edr_date_of_birth').value = '1995-01-01'")
    page.execute_script("document.querySelector('#edr_identity_card_expiry_date').value = '2031-05-20'")
    page.execute_script("document.querySelector('#edr_hire_date').value = '2026-10-01'")
    select "ريسبشن", from: "الوظيفة"
    fill_in "اسم جهة اتصال الطوارئ", with: "فاطمة حسن"
    fill_in "رقم هاتف الطوارئ", with: "01229876543"
    fill_in "صلة القرابة", with: "والدة"
    attach_file "employee_data_request[id_front]", Rails.root.join("spec/fixtures/files/test_image.png"), make_visible: true
    attach_file "employee_data_request[id_back]",  Rails.root.join("spec/fixtures/files/test_image.png"), make_visible: true
    fill_in "employee_data_request[manager_notes]", with: "اتكلمت مع الموظف واتفقنا على مرتب 9000 جنيه + عمولة."
    no_horizontal_scroll!
    if ENV["SCREENSHOT_DIR"]
      set_viewport(375, page.evaluate_script("document.documentElement.scrollHeight"))
      screenshot("edr-form-ar-375-light")
    end
    click_button "إرسال للمراجعة"

    expect(page).to have_text("تم إرسال الطلب للمراجعة.")
    expect(page).to have_css(".badge", text: "بانتظار المراجعة")
    request = EmployeeDataRequest.last

    sign_in reviewer
    visit employee_data_request_path(request)
    images_loaded!(".edr-photo__img")
    expect(page).to have_text("اتكلمت مع الموظف واتفقنا على مرتب 9000 جنيه + عمولة.")

    first(".edr-photo__thumb").click
    expect(page).to have_css("dialog.edr-viewer[open]")
    within("dialog.edr-viewer[open]") do
      click_button "تكبير"
      expect(page).to have_css(".edr-viewer__stage.is-zoomed")
      click_button "إغلاق"
    end
    expect(page).to have_no_css("dialog.edr-viewer[open]")

    expect(page).to have_css("[data-testid='verification-checks']")
    # Reviewer corrects a typo right in the review form, then approves.
    select "كوافير", from: "review_job_title"
    screenshot("edr-review-correcting-ar-375-light")
    accept_confirm { click_button "اعتماد البيانات" }
    expect(page).to have_text("تم اعتماد البيانات وإنشاء ملف الموظف.")
    employee = request.reload.employee
    expect(employee.full_name).to eq("محمد أحمد علي حسن")
    expect(employee).to have_attributes(job_title: "كوافير", hire_date: Date.new(2026, 10, 1),
                                        identity_card_expiry_date: Date.new(2031, 5, 20),
                                        emergency_contact_name: "فاطمة حسن", emergency_contact_phone: "01229876543",
                                        emergency_contact_relationship: "والدة")
    expect(request.revisions.map(&:source)).to eq(%w[submission reviewer_correction])
    expect(page).to have_css("[data-testid='correction-diff']", text: "ريسبشن")
    expect(employee.permission_role_id).to be_nil
    expect(employee.salary_profiles).to be_empty
    expect(employee.shift_assignments).to be_empty
  end

  %w[ar en].each do |locale|
    [ 1280, 375 ].each do |width|
      %w[light dark].each do |theme|
        it "lays out the review page and list at #{width}px (#{locale}, #{theme})" do
          reviewer.update!(preferred_locale: locale)
          request = create(:employee_data_request, business: business, submitted_by: manager,
                                                   manager_notes: "اتكلمت مع الموظف واتفقنا على مرتب 9000 جنيه + عمولة.")
          set_viewport(width)
          sign_in reviewer
          visit employee_data_request_path(request)
          set_theme(theme)

          expect(page.evaluate_script("document.documentElement.dir")).to eq(locale == "ar" ? "rtl" : "ltr")
          expect(page.evaluate_script("document.documentElement.classList.contains('dark')")).to eq(theme == "dark")
          expect(page).to have_text(locale == "ar" ? "طلب إضافة موظف" : "New Employee Request")
          expect(page).to have_button(locale == "ar" ? "اعتماد البيانات" : "Approve Data")
          expect(css(".edr-card", "backgroundColor")).to eq(theme == "dark" ? "rgb(17, 34, 64)" : "rgb(255, 255, 255)")
          expect(css(".edr-show__name", "color")).to eq(theme == "dark" ? "rgb(232, 237, 244)" : "rgb(15, 37, 64)")
          images_loaded!(".edr-show__docs .edr-photo__img")
          no_horizontal_scroll!
          if ENV["SCREENSHOT_DIR"]
            set_viewport(width, [ page.evaluate_script("document.documentElement.scrollHeight"), 900 ].max)
            screenshot("edr-review-#{locale}-#{width}-#{theme}")
            set_viewport(width)
          end

          visit employee_data_requests_path
          expect(page).to have_css("[data-testid='pending-alert']")
          no_horizontal_scroll!
          screenshot("edr-list-#{locale}-#{width}-#{theme}")
        end
      end
    end
  end
end
