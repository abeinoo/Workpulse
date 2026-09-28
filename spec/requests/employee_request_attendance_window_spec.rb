require "rails_helper"

# Web/API flows for cross-day punch-correction protection.
RSpec.describe "Employee request attendance-window protection", type: :request do
  let(:business) { create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 0) }
  let(:branch)   { create(:branch, business: business) }
  let(:employee) { create(:user, business: business, preferred_locale: "ar") }
  let(:manager) do
    role = create(:permission_role, business: business, permissions: %w[view_requests approve_requests])
    create(:user, business: business, permission_role: role, preferred_locale: "ar")
  end
  let(:riyadh)    { ActiveSupport::TimeZone["Asia/Riyadh"] }
  let(:work_date) { Date.new(2026, 9, 13) }

  def at(day, hour, min = 0) = riyadh.local(2026, 9, day, hour, min)

  # Shift clock times are timezone-aware `time` columns that the app writes and
  # reads under the business zone (set_business_timezone), so create it there.
  let(:assignment) do
    shift = Time.use_zone(business.timezone) do
      create(:shift, :fixed_time, business: business, name: "Evening", start_time: "19:00", end_time: "02:00")
    end
    create(:shift_assignment, user: employee, branch: branch, effective_from: Date.new(2026, 1, 1), shift: shift)
  end
  let!(:record) do
    create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment,
           date: work_date, work_date: work_date,
           check_in_at: at(13, 19, 5), check_out_at: at(14, 0, 3), status: "present", worked_minutes: 298)
  end

  before { branch.update_column(:branch_manager_id, manager.id) }

  def correction_params(proposed_date:, proposed_time:, type: "wrong_check_in_time", **extra)
    { employee_request: { request_type: "punch_correction", correction_type: type,
                          requested_for_date: work_date.iso8601, proposed_date: proposed_date&.iso8601,
                          proposed_time: proposed_time, reason: "Forgot to punch", **extra } }
  end

  def html = Nokogiri::HTML(response.body)

  describe "employee creates a request" do
    before { sign_in employee }

    it "warns (Arabic) and does not save an out-of-window punch until acknowledged" do
      expect {
        post employee_requests_path, params: correction_params(proposed_date: Date.new(2026, 9, 12), proposed_time: "15:10")
      }.not_to change(EmployeeRequest, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      warning = html.at_css("[data-testid='window-warning']").text.squish
      expect(warning).to include("تنبيه: الوقت المقترح خارج نطاق يوم العمل")
      expect(warning).to include("يوم العمل: 13 سبتمبر 2026")
      expect(warning).to include("الوقت المقترح: 12 سبتمبر 2026 — 03:10 PM")
      expect(warning).to include("يرجى مراجعة التاريخ والوقت قبل إرسال الطلب.")
      # The entered values are redisplayed unchanged.
      expect(html.at_css("#employee_request_proposed_date")["value"]).to eq("2026-09-12")
    end

    it "saves the request exactly as entered after explicit acknowledgement" do
      expect {
        post employee_requests_path, params: correction_params(proposed_date: Date.new(2026, 9, 12),
                                                               proposed_time: "15:10", acknowledge_out_of_window: "1")
      }.to change(EmployeeRequest, :count).by(1)
      req = EmployeeRequest.last
      expect(req.proposed_date).to eq(Date.new(2026, 9, 12))
      expect(req.proposed_time).to eq("15:10")
    end

    it "saves a normal in-window request directly (overnight check-out after midnight)" do
      expect {
        post employee_requests_path, params: correction_params(proposed_date: Date.new(2026, 9, 14),
                                                               proposed_time: "01:30", type: "wrong_check_out_time")
      }.to change(EmployeeRequest, :count).by(1)
      expect(response).to redirect_to(employee_requests_path)
    end
  end

  describe "reviewer" do
    let!(:bad_request) do
      create(:employee_request, :punch_correction, user: employee, correction_type: "wrong_check_in_time",
             requested_for_date: work_date, proposed_date: Date.new(2026, 9, 12), proposed_time: "15:10")
    end

    before { sign_in manager }

    it "sees a prominent warning, the full window context, and a confirmation checkbox" do
      get employee_request_path(bad_request)

      alert = html.at_css("[data-testid='window-alert']").text.squish
      expect(alert).to include("هذا التعديل خارج نطاق الشيفت المتوقع وقد يؤثر على مدة العمل.")
      expect(alert).to include("الوقت المقترح خارج نطاق يوم العمل")
      expect(alert).not_to include("32 ساعة") # duration has its own card
      expect(html.at_css("[data-testid='resulting-duration-value']").text).to eq("32 ساعة و53 دقيقة")
      expect(alert).to include("12 سبتمبر 2026 — 03:10 PM")

      panel = html.at_css("[data-testid='attendance-window']")
      expect(panel.at_css("[data-testid='window-work-date']").text).to include("13 سبتمبر 2026")
      expect(panel.at_css("[data-testid='window-shift']").text.squish)
        .to include("Evening").and include("13 سبتمبر 2026 — 07:00 PM").and include("14 سبتمبر 2026 — 02:00 AM")
      expect(panel.text.squish).to include("13 سبتمبر 2026 — 07:05 PM").and include("14 سبتمبر 2026 — 12:03 AM")
      expect(panel.at_css("[data-testid='window-final']").text.squish).to eq("12 سبتمبر 2026 — 03:10 PM")
      expect(panel.at_css("[data-testid='window-status']").text).to include("خارج نطاق يوم العمل")

      confirm = html.at_css("[data-testid='window-confirm']")
      expect(confirm.text).to include("هل أنت متأكد من اعتماد هذا التعديل؟")
      expect(confirm.at_css("input[name='confirm_out_of_window'][required]")).to be_present
    end

    it "G. the server rejects approval without the confirmation flag" do
      patch approve_employee_request_path(bad_request), params: { approved_time: "15:10" }
      expect(flash[:alert]).to eq(I18n.t("requests.errors.attendance_window_confirmation_required", locale: :ar))
      expect(bad_request.reload).to be_pending
      expect(record.reload.check_in_at).to eq(at(13, 19, 5))
    end

    it "H. approval proceeds with explicit confirmation and the abnormal duration is flagged" do
      patch approve_employee_request_path(bad_request), params: { approved_time: "15:10", confirm_out_of_window: "1" }
      expect(bad_request.reload).to be_approved

      get employee_request_path(bad_request)
      duration = html.at_css("[data-testid='duration-alert']").text.squish
      expect(duration).to include("مدة عمل غير طبيعية: 32 ساعة و53 دقيقة")
      expect(duration).to include("تتطلب مراجعة")
      # The approved out-of-window correction stays visibly flagged for traceability.
      expect(html.at_css("[data-testid='window-status']").text).to include("خارج نطاق يوم العمل")
    end

    it "shows the duration warning in English on the attendance record page" do
      Requests::Approver.approve(request: bad_request, reviewed_by: manager, confirm_out_of_window: true)
      manager.update!(preferred_locale: "en")
      owner = create(:user, :owner, business: business, preferred_locale: "en")
      sign_in owner
      get attendance_record_path(record)
      expect(html.at_css("html")["dir"]).to eq("ltr")
      expect(html.at_css("[data-testid='duration-alert']").text.squish)
        .to include("Abnormal work duration: 32h 53m").and include("requires review")
    end

    it "shows an in-window request without warnings and with an inside status" do
      ok = create(:employee_request, :punch_correction, user: employee, correction_type: "wrong_check_out_time",
                  requested_for_date: work_date, proposed_date: Date.new(2026, 9, 14), proposed_time: "01:30")
      get employee_request_path(ok)
      expect(html.at_css("[data-testid='window-alert']")).to be_nil
      expect(html.at_css("[data-testid='window-confirm']")).to be_nil
      expect(html.at_css("[data-testid='window-status']").text).to include("داخل نطاق يوم العمل")
      expect(html.at_css("[data-testid='window-final']").text.squish).to eq("14 سبتمبر 2026 — 01:30 AM")
    end
  end

  describe "API approval" do
    let!(:bad_request) do
      create(:employee_request, :punch_correction, user: employee, correction_type: "wrong_check_in_time",
             requested_for_date: work_date, proposed_date: Date.new(2026, 9, 12), proposed_time: "15:10")
    end

    before { sign_in manager }

    it "G. is rejected server-side without confirm_out_of_window" do
      patch "/api/v1/employee_requests/#{bad_request.id}/approve", as: :json
      expect(response).not_to have_http_status(:ok)
      expect(bad_request.reload).to be_pending
    end

    it "H. succeeds with confirm_out_of_window" do
      patch "/api/v1/employee_requests/#{bad_request.id}/approve", params: { confirm_out_of_window: true }, as: :json
      expect(response).to have_http_status(:ok)
      expect(bad_request.reload).to be_approved
    end
  end
end
