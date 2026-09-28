require "rails_helper"

# Punch-correction detail page: 12-hour (AM/PM) time display and the
# "Reviewer Changes" section showing original proposed value → reviewed value.
RSpec.describe "EmployeeRequests show — reviewer changes", type: :request do
  let(:business)  { create(:business, timezone: "Asia/Riyadh") }
  let(:branch)    { create(:branch, business: business) }
  let(:employee)  { create(:user, business: business, preferred_locale: "en") }
  let(:manager) do
    role = create(:permission_role, business: business,
                  permissions: %w[view_requests approve_requests])
    create(:user, business: business, permission_role: role,
           first_name: "Mahmoud", last_name: "Hosny", preferred_locale: "en")
  end
  let(:riyadh)    { ActiveSupport::TimeZone["Asia/Riyadh"] }
  let(:work_date) { Date.new(2026, 9, 14) }
  # 19:08 UTC = 22:08 Riyadh (UTC+3)
  let(:review_moment) { Time.utc(2026, 9, 14, 19, 8, 0) }

  let!(:attendance_record) do
    create(:attendance_record, user: employee, branch: branch,
           date: work_date, work_date: work_date,
           check_in_at:  riyadh.local(2026, 9, 14, 9, 30),
           check_out_at: riyadh.local(2026, 9, 14, 14, 5),
           status: "present", worked_minutes: 275)
  end

  # The attendance_record factory assigns the employee to `branch` (shift-driven
  # membership), which `manager` manages.
  before { branch.update_column(:branch_manager_id, manager.id) }

  def correction(type, proposed)
    create(:employee_request, :punch_correction, user: employee,
           correction_type: type, requested_for_date: work_date, proposed_time: proposed)
  end

  def approve_as_manager(request, approved_time)
    sign_in manager
    travel_to(review_moment) do
      # Several fixtures here are deliberately odd (e.g. a 03:10 PM check-in after a
      # 02:05 PM check-out) and fall outside the attendance window; these specs
      # cover the reviewer-change display, so the reviewer explicitly confirms.
      patch approve_employee_request_path(request),
            params: { approved_at: "#{request.proposed_punch_date.iso8601}T#{approved_time}",
                      confirm_out_of_window: "1" }
    end
    expect(request.reload).to be_approved
  end

  def show_as(user, request, locale:)
    user.update!(preferred_locale: locale)
    sign_in user
    get employee_request_path(request)
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body)
  end

  def reviewer_section(doc)
    doc.at_css("[data-testid='reviewer-changes']")
  end

  describe "reviewer approves without changing anything" do
    # A valid check-out (09:30 check-in → 15:10); dates are applied as entered.
    let(:request) { correction("wrong_check_out_time", "15:10") }

    before { approve_as_manager(request, "15:10") }

    it "states the proposed time was approved as-is and shows no fake change" do
      section = reviewer_section(show_as(manager, request, locale: "en"))
      expect(section.at_css("[data-testid='reviewer-approved-as-proposed']").text)
        .to include("Proposed time approved as submitted").and include("03:10 PM")
      expect(section.css(".review-change")).to be_empty
      expect(section.text).to include("Approved by").and include("Mahmoud Hosny")
      expect(section.text).not_to include("Changed by")
    end

    it "treats a seconds-suffixed but equal time as unchanged" do
      request.update_column(:approved_time, "15:10:00")
      section = reviewer_section(show_as(manager, request, locale: "en"))
      expect(section.css(".review-change")).to be_empty
    end
  end

  describe "reviewer changes the attendance (check-in) time" do
    let(:request) { correction("wrong_check_in_time", "15:10") }

    before { approve_as_manager(request, "02:07") }

    it "shows OLD → NEW for check-in only" do
      section = reviewer_section(show_as(manager, request, locale: "en"))
      row = section.at_css("[data-testid='reviewer-change-check_in']")
      expect(row.at_css(".info-card__label").text).to include("Check-In Time")
      expect(row.at_css(".review-change__old").text.strip).to eq("Sep 14, 2026 — 03:10 PM")
      expect(row.at_css(".review-change__new").text.strip).to eq("Sep 14, 2026 — 02:07 AM")
      expect(section.at_css("[data-testid='reviewer-change-check_out']")).to be_nil
      expect(section.at_css("[data-testid='reviewer-approved-as-proposed']")).to be_nil
    end

    it "shows the correct reviewer name and review timestamp (12-hour, business TZ)" do
      section = reviewer_section(show_as(employee, request, locale: "en"))
      expect(section.text).to include("Changed by").and include("Mahmoud Hosny")
      expect(section.text.squish).to include("Review date Sep 14, 2026 10:08 PM")
    end

    it "keeps the stored request values and attendance time unchanged by display" do
      expect(request.proposed_time).to eq("15:10")   # original never overwritten
      expect(request.approved_punch_at).to eq(riyadh.local(2026, 9, 14, 2, 7))
      expect(request.reviewed_at).to eq(review_moment)
      expect(request.reviewed_by).to eq(manager)
      expect(attendance_record.reload.check_in_at).to eq(riyadh.local(2026, 9, 14, 2, 7))
      expect(attendance_record.check_out_at).to eq(riyadh.local(2026, 9, 14, 14, 5))

      show_as(manager, request, locale: "ar")
      request.reload
      expect(request.proposed_time).to eq("15:10")
      expect(request.approved_punch_at).to eq(riyadh.local(2026, 9, 14, 2, 7))
    end
  end

  describe "reviewer changes the leave (check-out) time" do
    let(:request) { correction("wrong_check_out_time", "14:05") }

    before { approve_as_manager(request, "18:30") }

    it "shows OLD → NEW for check-out only" do
      section = reviewer_section(show_as(manager, request, locale: "en"))
      row = section.at_css("[data-testid='reviewer-change-check_out']")
      expect(row.at_css(".info-card__label").text).to include("Check-Out Time")
      expect(row.at_css(".review-change__old").text.strip).to eq("Sep 14, 2026 — 02:05 PM")
      expect(row.at_css(".review-change__new").text.strip).to eq("Sep 14, 2026 — 06:30 PM")
      expect(section.at_css("[data-testid='reviewer-change-check_in']")).to be_nil
      expect(attendance_record.reload.check_out_at).to eq(riyadh.local(2026, 9, 14, 18, 30))
    end
  end

  describe "both attendance and leave times changed" do
    # A punch-correction request targets a single punch, so "both changed" means
    # two reviewed requests for the same day; each page shows its own change and
    # never a change for the other field.
    let(:check_in_request)  { correction("wrong_check_in_time", "15:10") }
    let(:check_out_request) { correction("wrong_check_out_time", "14:05") }

    before do
      approve_as_manager(check_in_request, "08:00")
      approve_as_manager(check_out_request, "17:45")
    end

    it "shows each change with its own field and values" do
      in_section  = reviewer_section(show_as(manager, check_in_request, locale: "en"))
      out_section = reviewer_section(show_as(manager, check_out_request, locale: "en"))

      expect(in_section.at_css("[data-testid='reviewer-change-check_in'] .review-change__new").text.strip).to eq("Sep 14, 2026 — 08:00 AM")
      expect(in_section.at_css("[data-testid='reviewer-change-check_out']")).to be_nil
      expect(out_section.at_css("[data-testid='reviewer-change-check_out'] .review-change__new").text.strip).to eq("Sep 14, 2026 — 05:45 PM")
      expect(out_section.at_css("[data-testid='reviewer-change-check_in']")).to be_nil

      attendance_record.reload
      expect(attendance_record.check_in_at).to eq(riyadh.local(2026, 9, 14, 8, 0))
      expect(attendance_record.check_out_at).to eq(riyadh.local(2026, 9, 14, 17, 45))
    end
  end

  describe "12-hour display across the page" do
    let(:request) { correction("wrong_check_in_time", "15:10") }

    before { approve_as_manager(request, "02:07") }

    it "renders every time on the page in AM/PM with no 24-hour leftovers" do
      doc  = show_as(manager, request, locale: "en")
      text = doc.at_css(".form-page").text.squish
      expect(text).to include("03:10 PM")                 # proposed punch
      expect(text).to include("02:07 AM")                 # approved time
      expect(text).to include("09:30 AM")                 # original check-in snapshot
      expect(text).to include("02:05 PM")                 # original check-out snapshot
      expect(text).to include("Sep 14, 2026 10:08 PM")    # reviewed at
      expect(text).not_to match(/\b(15:10|14:05|22:08)\b/)
    end
  end

  describe "locale direction" do
    let(:request) { correction("wrong_check_in_time", "15:10") }

    before { approve_as_manager(request, "02:07") }

    it "renders Arabic RTL with LTR-isolated clock values" do
      doc = show_as(manager, request, locale: "ar")
      expect(doc.at_css("html")["dir"]).to eq("rtl")
      section = reviewer_section(doc)
      expect(section.at_css(".info-card__section-title").text).to include("تعديلات المراجع")
      expect(section.text).to include("وقت الحضور").and include("تم التعديل بواسطة").and include("تاريخ المراجعة")
      expect(section.text.squish).to include("14 سبتمبر 2026 10:08 PM")
      clocks = section.css("bdi.clock-12h")
      expect(clocks).not_to be_empty
      expect(clocks.map { |c| c["dir"] }.uniq).to eq([ "ltr" ])
    end

    it "renders English LTR" do
      doc = show_as(manager, request, locale: "en")
      expect(doc.at_css("html")["dir"]).to eq("ltr")
      expect(reviewer_section(doc).at_css(".info-card__section-title").text).to include("Reviewer Changes")
    end
  end

  describe "original attendance section: date + 12-hour time per punch" do
    let(:request) { correction("wrong_check_out_time", "02:30") }
    # Overnight: check-in 12 Sep 21:10 Riyadh; check-out stored as 12 Sep 23:05 UTC,
    # which is 13 Sep 02:05 in Riyadh — its date must follow the business timezone.
    let(:check_in)  { riyadh.local(2026, 9, 12, 21, 10) }
    let(:check_out) { Time.utc(2026, 9, 12, 23, 5) }

    before { attendance_record.update_columns(check_in_at: check_in, check_out_at: check_out) }

    def original_rows(doc)
      title = I18n.t("requests.show.original_attendance", locale: I18n.locale)
      card  = doc.css(".info-card").find { |c| c.at_css(".info-card__section-title")&.text&.strip == title }
      card.css(".info-card__row").map { |r| r.css("span").last.text.squish }
    end

    it "shows each punch with its own date in English" do
      doc = I18n.with_locale(:en) { show_as(manager, request, locale: "en") }
      rows = I18n.with_locale(:en) { original_rows(doc) }
      expect(rows[0]).to eq("Sep 12, 2026 — 09:10 PM")
      expect(rows[1]).to eq("Sep 13, 2026 — 02:05 AM")
    end

    it "shows each punch with its own date in Arabic with an LTR-isolated clock" do
      doc = show_as(manager, request, locale: "ar")
      rows = I18n.with_locale(:ar) { original_rows(doc) }
      expect(rows[0]).to eq("12 سبتمبر 2026 — 09:10 PM")
      expect(rows[1]).to eq("13 سبتمبر 2026 — 02:05 AM")
      expect(doc.at_css("html")["dir"]).to eq("rtl")
    end

    it "does not change the stored timestamps" do
      show_as(manager, request, locale: "ar")
      attendance_record.reload
      expect(attendance_record.check_in_at).to eq(check_in)
      expect(attendance_record.check_out_at).to eq(check_out)
    end

    it "still shows Missing when there is no check-out" do
      attendance_record.update_columns(check_out_at: nil)
      doc  = I18n.with_locale(:en) { show_as(manager, request, locale: "en") }
      rows = I18n.with_locale(:en) { original_rows(doc) }
      expect(rows[0]).to eq("Sep 12, 2026 — 09:10 PM")
      expect(rows[1]).to eq("Missing")
    end
  end

  describe "requests without a review" do
    it "does not render the section while pending" do
      request = correction("wrong_check_in_time", "15:10")
      expect(reviewer_section(show_as(manager, request, locale: "en"))).to be_nil
    end

    it "does not render the section for rejected requests" do
      request = correction("wrong_check_in_time", "15:10")
      request.update!(status: "rejected", reviewed_by: manager, reviewed_at: review_moment)
      expect(reviewer_section(show_as(manager, request, locale: "en"))).to be_nil
    end
  end
end
