require "rails_helper"

# Reviewer-only validation details on a punch-correction request are rendered
# only for authorized reviewers (EmployeeRequestPolicy#review_details?) — never
# for the requester or other non-approvers, and not merely hidden with CSS.
RSpec.describe "Employee request reviewer-only details visibility", type: :request do
  let(:business) { create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 0) }
  let(:branch)   { create(:branch, business: business) }
  let(:employee) { create(:user, business: business, preferred_locale: "ar") }
  let(:manager) do
    role = create(:permission_role, business: business, permissions: %w[view_requests approve_requests])
    create(:user, business: business, permission_role: role, first_name: "Mahmoud", last_name: "Hosny",
                  preferred_locale: "ar")
  end
  let(:riyadh)    { ActiveSupport::TimeZone["Asia/Riyadh"] }
  let(:work_date) { Date.new(2026, 9, 13) }

  def at(day, hour, min = 0) = riyadh.local(2026, 9, day, hour, min)

  # Overnight 19:00 → 02:00 shift; checked in 13 Sep 19:05, out 14 Sep 00:03.
  let!(:record) do
    shift = Time.use_zone(business.timezone) do
      create(:shift, :fixed_time, business: business, name: "Evening", start_time: "19:00", end_time: "02:00")
    end
    assignment = create(:shift_assignment, user: employee, branch: branch, shift: shift,
                        effective_from: Date.new(2026, 1, 1))
    create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment,
           date: work_date, work_date: work_date,
           check_in_at: at(13, 19, 5), check_out_at: at(14, 0, 3), status: "present", worked_minutes: 298)
  end

  # The reported case: out of window and a 32h 53m resulting duration.
  let!(:request_record) do
    create(:employee_request, :punch_correction, user: employee, correction_type: "wrong_check_in_time",
           requested_for_date: work_date, proposed_date: Date.new(2026, 9, 12), proposed_time: "15:10",
           reason: "نسيت البصمة")
  end

  before { branch.update_column(:branch_manager_id, manager.id) }

  def reviewer_only_selectors = %w[
    [data-testid='window-alert'] [data-testid='attendance-window'] [data-testid='resulting-duration']
    [data-testid='resulting-duration-warning'] [data-testid='window-confirm'] [data-testid='duration-alert']
    input[name='confirm_out_of_window']
  ]

  # Strings that only the reviewer-only sections produce. Checked against the
  # raw response body so nothing leaks, even hidden.
  def reviewer_only_strings
    [
      I18n.t("requests.show.window.title", locale: :ar),              # فحص نطاق يوم العمل
      I18n.t("requests.show.resulting_duration.title", locale: :ar),  # مدة العمل بعد التعديل
      I18n.t("requests.show.window.alert_outside_title", locale: :ar),
      I18n.t("requests.show.window.confirm_question", locale: :ar),
      "32 ساعة و53 دقيقة",                                             # resulting duration
      "Evening",                                                        # shift name
      "07:00 PM", "02:00 AM"                                            # shift start / end
    ]
  end

  def get_show(user)
    sign_in user
    get employee_request_path(request_record)
    Nokogiri::HTML(response.body)
  end

  def expect_no_reviewer_details(doc)
    reviewer_only_selectors.each { |sel| expect(doc.at_css(sel)).to be_nil, "unexpected #{sel}" }
    reviewer_only_strings.each { |str| expect(response.body).not_to include(str), "leaked #{str.inspect}" }
  end

  describe "employee viewing their own request" do
    it "shows only the normal request information while pending" do
      doc = get_show(employee)
      expect(response).to have_http_status(:ok)
      expect_no_reviewer_details(doc)

      text = doc.at_css(".form-page").text.squish
      expect(text).to include(I18n.t("requests.types.punch_correction", locale: :ar))
      expect(text).to include("12 سبتمبر 2026 — 03:10 PM")                 # proposed punch
      expect(text).to include("نسيت البصمة")                               # reason
      expect(doc.at_css(".page-header .badge").text.squish).to be_present  # status
    end

    it "shows review information but no validation details after approval" do
      Requests::Approver.approve(request: request_record, reviewed_by: manager, confirm_out_of_window: true)
      doc = get_show(employee)

      expect_no_reviewer_details(doc)
      expect(doc.at_css("[data-testid='reviewer-changes']").text).to include("Mahmoud Hosny")
      expect(doc.text).to include(I18n.t("requests.reviewed", locale: :ar))
    end
  end

  describe "authorized reviewer viewing the request" do
    it "keeps every validation detail visible" do
      doc = get_show(manager)

      reviewer_only_selectors.without("[data-testid='duration-alert']").each do |sel|
        expect(doc.at_css(sel)).to be_present, "missing #{sel}"
      end
      panel = doc.at_css("[data-testid='attendance-window']").text.squish
      expect(panel).to include("فحص نطاق يوم العمل").and include("13 سبتمبر 2026 — 07:05 PM")
        .and include("Evening").and include("14 سبتمبر 2026 — 02:00 AM").and include("خارج نطاق يوم العمل")
      expect(doc.at_css("[data-testid='resulting-duration-value']").text).to eq("32 ساعة و53 دقيقة")
      expect(doc.at_css("[data-testid='resulting-duration-warning']").text).to include("تتجاوز 24 ساعة")
      expect(doc.at_css("form[action$='/approve']")).to be_present
      expect(doc.at_css("form[action$='/reject']")).to be_present
    end

    it "still sees the post-approval abnormal-duration warning" do
      Requests::Approver.approve(request: request_record, reviewed_by: manager, confirm_out_of_window: true)
      doc = get_show(manager)
      expect(doc.at_css("[data-testid='duration-alert']").text).to include("32 ساعة و53 دقيقة")
      expect(doc.at_css("[data-testid='attendance-window']")).to be_present
    end
  end

  describe "other users" do
    it "a plain employee cannot open another employee's request at all" do
      stranger = create(:user, business: business)
      sign_in stranger
      get employee_request_path(request_record)
      # Out of the stranger's policy scope: 404 before any request data is loaded.
      # (The test-env debug 404 page quotes spec source, so check structure, not strings.)
      expect(response).to have_http_status(:not_found)
      doc = Nokogiri::HTML(response.body)
      reviewer_only_selectors.each { |sel| expect(doc.at_css(sel)).to be_nil }
    end

    it "a view-only user (view_requests, no approval) sees the request without reviewer details" do
      viewer = create(:user, business: business, preferred_locale: "ar",
                      permission_role: create(:permission_role, business: business,
                                              permissions: %w[view_requests],
                                              permission_scopes: { "view_requests" => "business" }))
      doc = get_show(viewer)
      expect(response).to have_http_status(:ok)
      expect_no_reviewer_details(doc)
    end

    it "an approver viewing their OWN request gets the requester view" do
      approver_request = create(:employee_request, :punch_correction, user: manager,
                                correction_type: "wrong_check_in_time", requested_for_date: work_date,
                                proposed_time: "09:00")
      sign_in manager
      get employee_request_path(approver_request)
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("[data-testid='attendance-window']")).to be_nil
      expect(doc.at_css("[data-testid='resulting-duration']")).to be_nil
    end
  end

  describe "approval behaviour is unchanged" do
    it "the reviewer still cannot approve without explicit confirmation" do
      sign_in manager
      patch approve_employee_request_path(request_record), params: { approved_time: "15:10" }
      expect(request_record.reload).to be_pending
      expect(flash[:alert]).to eq(I18n.t("requests.errors.attendance_window_confirmation_required", locale: :ar))
    end

    it "the reviewer approves with confirmation" do
      sign_in manager
      patch approve_employee_request_path(request_record), params: { approved_time: "15:10", confirm_out_of_window: "1" }
      expect(request_record.reload).to be_approved
      expect(record.reload.check_in_at).to eq(at(12, 15, 10))
    end

    it "the employee cannot approve their own request" do
      sign_in employee
      patch approve_employee_request_path(request_record), params: { approved_time: "15:10", confirm_out_of_window: "1" }
      expect(request_record.reload).to be_pending
    end
  end
end
