require "rails_helper"

# "Work duration after correction" card on the punch-correction review page.
RSpec.describe "Employee request resulting work duration", type: :request do
  let(:business) { create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 0) }
  let(:branch)   { create(:branch, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:manager) do
    role = create(:permission_role, business: business, permissions: %w[view_requests approve_requests])
    create(:user, business: business, permission_role: role, preferred_locale: "ar")
  end
  let(:riyadh)    { ActiveSupport::TimeZone["Asia/Riyadh"] }
  let(:work_date) { Date.new(2026, 9, 13) }

  def at(day, hour, min = 0) = riyadh.local(2026, 9, day, hour, min)

  # Overnight 19:00 → 02:00 shift, created under the business zone like the app does.
  let!(:record) do
    shift = Time.use_zone(business.timezone) do
      create(:shift, :fixed_time, business: business, start_time: "19:00", end_time: "02:00")
    end
    assignment = create(:shift_assignment, user: employee, branch: branch, shift: shift,
                        effective_from: Date.new(2026, 1, 1))
    create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment,
           date: work_date, work_date: work_date,
           check_in_at: at(13, 19, 5), check_out_at: at(14, 0, 3), status: "present", worked_minutes: 298)
  end

  before do
    branch.update_column(:branch_manager_id, manager.id)
    sign_in manager
  end

  def correction(type, time, date: nil)
    create(:employee_request, :punch_correction, user: employee, correction_type: type,
           requested_for_date: work_date, proposed_date: date, proposed_time: time)
  end

  def show(request)
    get employee_request_path(request)
    Nokogiri::HTML(response.body)
  end

  def card(doc)          = doc.at_css("[data-testid='resulting-duration']")
  def value(doc)         = doc.at_css("[data-testid='resulting-duration-value']").text.squish
  def warning(doc)       = doc.at_css("[data-testid='resulting-duration-warning']")
  def window_alert(doc)  = doc.at_css("[data-testid='window-alert']")

  # DOM order: the card must come before the approval form.
  def before_approval_form?(doc, node)
    form = doc.at_css("form[action$='/approve']")
    all  = doc.css("*").to_a
    all.index(node) < all.index(form)
  end

  it "normal duration: shows the value with normal styling and no warning" do
    doc = show(correction("wrong_check_out_time", "01:30", date: Date.new(2026, 9, 14))) # 19:05 → 14 Sep 01:30
    expect(card(doc).at_css(".info-card__section-title").text).to include("مدة العمل بعد التعديل")
    expect(value(doc)).to eq("6 ساعة و25 دقيقة")
    expect(card(doc)["class"]).not_to include("resulting-duration--")
    expect(warning(doc)).to be_nil
    expect(before_approval_form?(doc, card(doc))).to be true
  end

  it "legitimate overnight shift 19:00 → 02:00: normal duration, inside the window, no warnings" do
    doc = show(correction("wrong_check_out_time", "02:00", date: Date.new(2026, 9, 14)))
    expect(value(doc)).to eq("6 ساعة و55 دقيقة")
    expect(warning(doc)).to be_nil
    expect(window_alert(doc)).to be_nil
    expect(doc.at_css("[data-testid='window-status']").text).to include("داخل نطاق يوم العمل")
  end

  it "> 16 hours: shows a (non-critical) warning before the approval action" do
    doc = show(correction("wrong_check_in_time", "07:00")) # 13 Sep 07:00 → 14 Sep 00:03
    expect(value(doc)).to eq("17 ساعة و3 دقيقة")
    expect(warning(doc)["data-severity"]).to eq("suspicious")
    expect(warning(doc)["class"]).to include("alert-warning")
    expect(warning(doc).text.squish).to include("⚠️ مدة عمل غير طبيعية").and include("هذه المدة تتجاوز 16 ساعة وتتطلب مراجعة.")
    expect(window_alert(doc)).to be_nil # inside the window
    expect(before_approval_form?(doc, warning(doc))).to be true
  end

  it "> 24 hours: shows a critical warning" do
    doc = show(correction("wrong_check_in_time", "00:00")) # 13 Sep 00:00 → 14 Sep 00:03
    expect(value(doc)).to eq("24 ساعة و3 دقيقة")
    expect(warning(doc)["data-severity"]).to eq("critical")
    expect(warning(doc)["class"]).to include("alert-danger")
    expect(warning(doc).text.squish).to include("🔴 مدة عمل غير طبيعية").and include("هذه المدة تتجاوز 24 ساعة وتتطلب مراجعة.")
  end

  it "honours the configured thresholds" do
    business.update!(attendance_suspicious_duration_hours: 5, attendance_critical_duration_hours: 6)
    doc = show(correction("wrong_check_out_time", "01:30", date: Date.new(2026, 9, 14))) # 6h25m
    expect(warning(doc)["data-severity"]).to eq("critical")
    expect(warning(doc).text).to include("هذه المدة تتجاوز 6 ساعة")
  end

  it "the reported case: out-of-window + abnormal duration shows both warnings separately" do
    doc = show(correction("wrong_check_in_time", "15:10", date: Date.new(2026, 9, 12)))

    expect(window_alert(doc).text.squish).to include("⚠️ الوقت المقترح خارج نطاق يوم العمل")
    expect(window_alert(doc).text).not_to include("32 ساعة") # the time warning carries no duration
    expect(window_alert(doc).at_css("[data-testid='resulting-duration-warning']")).to be_nil

    expect(value(doc)).to eq("32 ساعة و53 دقيقة")
    expect(warning(doc).text.squish).to include("🔴 مدة عمل غير طبيعية").and include("هذه المدة تتجاوز 24 ساعة وتتطلب مراجعة.")
    expect(before_approval_form?(doc, warning(doc))).to be true

    # Existing confirmation requirement is still rendered.
    expect(doc.at_css("[data-testid='window-confirm'] input[name='confirm_out_of_window'][required]")).to be_present
  end

  it "reviewer still cannot approve an out-of-window request without explicit confirmation" do
    request = correction("wrong_check_in_time", "15:10", date: Date.new(2026, 9, 12))
    patch approve_employee_request_path(request), params: { approved_time: "15:10" }

    expect(request.reload).to be_pending
    expect(flash[:alert]).to eq(I18n.t("requests.errors.attendance_window_confirmation_required", locale: :ar))
    expect(record.reload.check_in_at).to eq(at(13, 19, 5))
  end

  it "rendering the projection never changes the stored attendance record" do
    show(correction("wrong_check_in_time", "15:10", date: Date.new(2026, 9, 12)))
    record.reload
    expect(record.check_in_at).to eq(at(13, 19, 5))
    expect(record.check_out_at).to eq(at(14, 0, 3))
    expect(record.worked_minutes).to eq(298)
  end

  it "uses the same result Attendance::RecordRecomputer produces on approval" do
    request = correction("wrong_check_in_time", "15:10", date: Date.new(2026, 9, 12))
    projected = value(show(request))
    Requests::Approver.approve(request: request, reviewed_by: manager, confirm_out_of_window: true)
    expect(record.reload.worked_minutes).to eq((32 * 60) + 53)
    expect(projected).to eq("32 ساعة و53 دقيقة")
  end

  it "renders in English LTR" do
    manager.update!(preferred_locale: "en")
    doc = show(correction("wrong_check_in_time", "15:10", date: Date.new(2026, 9, 12)))
    expect(doc.at_css("html")["dir"]).to eq("ltr")
    expect(card(doc).text.squish).to include("Work duration after correction").and include("32h 53m")
    expect(warning(doc).text.squish).to include("Abnormal work duration").and include("exceeds 24 hours and requires review")
  end
end
