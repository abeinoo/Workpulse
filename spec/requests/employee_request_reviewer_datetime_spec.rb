require "rails_helper"

# The reviewer edits the FINAL punch of a punch correction through ONE datetime
# input (approved_at). The employee's proposal is preserved; the final datetime
# is stored as one datetime (approved_punch_at), applied literally (never
# shifted across midnight), and every window / duration / confirmation check
# runs on it.
RSpec.describe "Punch correction review: single approved datetime input", type: :request do
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
  def sep(day) = Date.new(2026, 9, day)

  # Normal overnight shift 19:00 → 02:00; checked in 13 Sep 19:05, out 14 Sep 00:03.
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

  before { branch.update_column(:branch_manager_id, manager.id) }

  def correction(type, time, date:)
    create(:employee_request, :punch_correction, user: employee, correction_type: type,
           requested_for_date: work_date, proposed_date: date, proposed_time: time)
  end

  # approved_at is the datetime-local value the single input submits.
  def approve(request, approved_at: nil, confirm: nil)
    sign_in manager
    patch approve_employee_request_path(request),
          params: { approved_at: approved_at, confirm_out_of_window: confirm }.compact
    request.reload
  end

  def page_for(user, request, **query)
    sign_in user
    get employee_request_path(request, query)
    Nokogiri::HTML(response.body)
  end

  def form(doc) = doc.at_css("form[action$='/approve']")
  def audit(request) = AuditLog.where(auditable: request, action: "approve").last

  describe "review form" do
    it "has exactly ONE datetime input, labelled and prefilled with the proposal" do
      request = correction("missing_check_in", "15:10", date: sep(12))
      f = form(page_for(manager, request))

      inputs = f.css("input[name='approved_at']")
      expect(inputs.size).to eq(1)
      expect(inputs.first["type"]).to eq("datetime-local")
      expect(inputs.first["value"]).to eq("2026-09-12T15:10")
      expect(f.at_css("label[for='approved_at']").text).to eq("التاريخ والوقت المعتمد")
      expect(inputs.first["data-datepicker-mode-value"]).to eq("datetime")
      expect(inputs.first["data-datepicker-alt-format-value"]).to eq("d/m/Y, h:i K") # DD/MM/YYYY, hh:mm AM/PM
      expect(inputs.first["data-datepicker-time24hr-value"]).to eq("false")
      # No separate date or time inputs anywhere in the reviewer form.
      expect(f.css("input[type='date'], input[type='time'], input[name='approved_date'], input[name='approved_time']")).to be_empty
    end

    it "shows the correction type" do
      request = correction("missing_check_in", "15:10", date: sep(12))
      doc = page_for(manager, request)
      expect(doc.at_css("[data-testid='review-correction-type']").text.squish)
        .to eq("نوع التعديل: #{I18n.t('requests.correction_types.missing_check_in', locale: :ar)}")
    end
  end

  describe "A/D. reviewer changes date + time through the single input" do
    let(:request) { correction("missing_check_in", "15:10", date: sep(12)) } # 12 Sep 03:10 PM — wrong day

    it "E. stores ONE final datetime, applies it, and keeps the proposal untouched" do
      approve(request, approved_at: "2026-09-13T19:00")

      expect(request).to be_approved
      expect(request.approved_punch_at).to eq(at(13, 19))
      expect(request).to have_attributes(proposed_date: sep(12), proposed_time: "15:10", approved_time: nil)
      expect(record.reload.check_in_at).to eq(at(13, 19)) # in-window → no confirmation needed
      expect(record.worked_minutes).to eq(303)
    end

    it "shows proposal, final datetime and the reviewer modification separately" do
      approve(request, approved_at: "2026-09-13T19:00")
      manager.update!(preferred_locale: "en")
      doc = page_for(manager, request)

      expect(doc.at_css("[data-testid='window-proposal']").text.squish).to eq("Sep 12, 2026 — 03:10 PM")
      expect(doc.at_css("[data-testid='window-final']").text.squish)
        .to include("Sep 13, 2026 — 07:00 PM").and include("Changed by reviewer")
      change = doc.at_css("[data-testid='reviewer-change-check_in']")
      expect(change.at_css(".review-change__old").text.squish).to eq("Sep 12, 2026 — 03:10 PM")
      expect(change.at_css(".review-change__new").text.squish).to eq("Sep 13, 2026 — 07:00 PM")
    end

    it "I. audits original vs final datetime, whether it changed, and the reviewer" do
      travel_to(Time.utc(2026, 9, 14, 19, 8)) { approve(request, approved_at: "2026-09-13T19:00") }
      log = audit(request)
      review = log.metadata["punch_review"]

      expect(log.actor).to eq(manager)
      expect(Time.iso8601(review["proposed_at"])).to eq(at(12, 15, 10))
      expect(Time.iso8601(review["final_at"])).to eq(at(13, 19))
      expect(review).to include("datetime_changed" => true, "change" => "date_and_time",
                                "date_changed" => true, "time_changed" => true,
                                "reviewer_id" => manager.id, "reviewer_name" => "Mahmoud Hosny")
      expect(Time.iso8601(review["reviewed_at"])).to eq(Time.utc(2026, 9, 14, 19, 8))
    end
  end

  describe "B. date-only change (checkout after midnight)" do
    # Employee entered the work date for an after-midnight check-out.
    let(:request) { correction("wrong_check_out_time", "01:30", date: sep(13)) }

    it "does not shift the date automatically: approval as proposed is refused" do
      approve(request, approved_at: "2026-09-13T01:30", confirm: "1")
      expect(request).to be_pending
      expect(flash[:alert]).to eq(I18n.t("requests.errors.check_out_before_check_in", locale: :ar))
      expect(record.reload.check_out_at).to eq(at(14, 0, 3))
    end

    it "E. applies the next-day date with the same time" do
      approve(request, approved_at: "2026-09-14T01:30")
      expect(request).to be_approved
      expect(request.approved_punch_at).to eq(at(14, 1, 30))
      expect(record.reload.check_out_at).to eq(at(14, 1, 30))
      expect(audit(request).metadata["punch_review"])
        .to include("change" => "date", "date_changed" => true, "time_changed" => false, "datetime_changed" => true)
    end
  end

  describe "C. time-only change" do
    let(:request) { correction("wrong_check_out_time", "01:30", date: sep(14)) }

    it "keeps the date and applies the new time" do
      approve(request, approved_at: "2026-09-14T01:45")
      expect(request.approved_punch_at).to eq(at(14, 1, 45))
      expect(record.reload.check_out_at).to eq(at(14, 1, 45))
      expect(audit(request).metadata["punch_review"]).to include("change" => "time", "date_changed" => false)
    end
  end

  describe "cross-midnight datetime chosen by the reviewer" do
    it "moves a check-out from 23:30 on the work date to 00:30 the next day exactly as selected" do
      request = correction("wrong_check_out_time", "23:30", date: sep(13))
      approve(request, approved_at: "2026-09-14T00:30")
      expect(record.reload.check_out_at).to eq(at(14, 0, 30))
      expect(record.worked_minutes).to eq(325)
    end
  end

  describe "G. out-of-window final datetime (moved to another work day)" do
    let(:request) { correction("wrong_check_out_time", "01:30", date: sep(14)) } # in-window proposal

    it "still requires confirmation, judged on the reviewer's final datetime" do
      approve(request, approved_at: "2026-09-15T01:30")

      expect(request).to be_pending
      expect(flash[:alert]).to eq(I18n.t("requests.errors.attendance_window_confirmation_required", locale: :ar))
      expect(response).to redirect_to(employee_request_path(request, approved_at: "2026-09-15T01:30"))
      expect(record.reload.check_out_at).to eq(at(14, 0, 3))
    end

    it "the redirected page re-checks that datetime and asks for confirmation" do
      doc = page_for(manager, request, approved_at: "2026-09-15T01:30")

      expect(form(doc).at_css("input[name='approved_at']")["value"]).to eq("2026-09-15T01:30")
      expect(doc.at_css("[data-testid='window-final']").text).to include("15 سبتمبر 2026 — 01:30 AM")
      expect(doc.at_css("[data-testid='window-status']").text).to include("خارج نطاق يوم العمل")
      expect(doc.at_css("[data-testid='window-confirm'] input[name='confirm_out_of_window'][required]")).to be_present
      expect(doc.at_css("[data-testid='resulting-duration-value']").text).to eq("30 ساعة و25 دقيقة")
    end

    it "is approved with explicit confirmation and applied literally" do
      approve(request, approved_at: "2026-09-15T01:30", confirm: "1")
      expect(request).to be_approved
      expect(record.reload.check_out_at).to eq(riyadh.local(2026, 9, 15, 1, 30))
      expect(record.duration_severity).to eq(:critical)
    end
  end

  it "refuses an invalid datetime" do
    request = correction("wrong_check_out_time", "01:30", date: sep(14))
    approve(request, approved_at: "2026-02-31T01:30")
    expect(request).to be_pending
    expect(flash[:alert]).to eq(I18n.t("requests.errors.invalid_approved_date", locale: :ar))
  end

  describe "H. the employee does not see reviewer-only details" do
    let(:request) { correction("missing_check_in", "15:10", date: sep(12)) }

    it "while pending: no datetime input, panel, duration or confirmation" do
      doc = page_for(employee, request)
      %w[input[name='approved_at'] [data-testid='attendance-window'] [data-testid='resulting-duration']
         [data-testid='window-confirm'] [data-testid='window-final']].each do |sel|
        expect(doc.at_css(sel)).to be_nil, "unexpected #{sel}"
      end
      expect(doc.text).to include("12 سبتمبر 2026 — 03:10 PM") # their own proposal
    end

    it "after approval: sees their proposal and the approved punch, still no validation details" do
      approve(request, approved_at: "2026-09-13T19:00")
      doc = page_for(employee, request)

      expect(doc.at_css("[data-testid='attendance-window']")).to be_nil
      expect(doc.at_css("[data-testid='resulting-duration']")).to be_nil
      text = doc.at_css(".form-page").text.squish
      expect(text).to include("12 سبتمبر 2026 — 03:10 PM").and include("13 سبتمبر 2026 — 07:00 PM")
    end
  end

  describe "J. normal overnight shift 19:00 → 02:00" do
    it "approves a 02:00 next-day check-out as proposed, without confirmation" do
      request = correction("wrong_check_out_time", "02:00", date: sep(14))
      approve(request, approved_at: "2026-09-14T02:00")
      expect(request).to be_approved
      expect(request.approved_punch_at).to eq(at(14, 2))
      expect(record.reload.check_out_at).to eq(at(14, 2))
      expect(record.worked_minutes).to eq(415)
      expect(record.duration_severity).to be_nil
      expect(audit(request).metadata["punch_review"]).to include("change" => "none", "datetime_changed" => false)
    end

    it "approves the proposal when no datetime is submitted (API-style call)" do
      request = correction("wrong_check_out_time", "02:00", date: sep(14))
      approve(request)
      expect(request.approved_punch_at).to eq(at(14, 2))
      expect(record.reload.check_out_at).to eq(at(14, 2))
    end
  end

  describe "history approved before the single datetime existed" do
    it "is still displayed as it was applied (legacy roll), not re-interpreted" do
      request = correction("wrong_check_out_time", "01:30", date: sep(13))
      request.update_columns(status: "approved", reviewed_at: Time.current, reviewed_by_id: manager.id,
                             original_check_in_at: at(13, 19, 5), original_check_out_at: at(14, 0, 3))
      expect(Requests::PunchCorrectionAssessment.for(request).effective_at).to eq(at(14, 1, 30))
    end
  end
end
