require "rails_helper"

# Cross-day punch-correction protection: the assessment, the server-side
# approval gate in Requests::Approver, and abnormal-duration flagging.
RSpec.describe "Punch correction attendance-window guard" do
  let(:business)  { create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 0) }
  let(:branch)    { create(:branch, business: business) }
  let(:employee)  { create(:user, business: business) }
  let(:manager)   { create(:user, business: business) }
  let(:riyadh)    { ActiveSupport::TimeZone["Asia/Riyadh"] }
  let(:work_date) { Date.new(2026, 9, 13) }

  def at(day, hour, min = 0) = riyadh.local(2026, 9, day, hour, min)

  let(:assignment) do
    create(:shift_assignment, user: employee, branch: branch, effective_from: Date.new(2026, 1, 1),
           shift: create(:shift, :fixed_time, business: business,
                         start_time: Time.zone.parse("19:00"), end_time: Time.zone.parse("02:00")))
  end

  # Overnight day: checked in 13 Sep 19:05, checked out 14 Sep 00:03.
  let!(:record) do
    create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment,
           date: work_date, work_date: work_date,
           check_in_at: at(13, 19, 5), check_out_at: at(14, 0, 3),
           status: "present", worked_minutes: 298)
  end

  # The reported bug: check-in "corrected" to 12 Sep 03:10 PM for work date 13 Sep.
  let(:bad_request) do
    create(:employee_request, :punch_correction, user: employee, correction_type: "wrong_check_in_time",
           requested_for_date: work_date, proposed_date: Date.new(2026, 9, 12), proposed_time: "15:10")
  end

  describe Requests::PunchCorrectionAssessment do
    it "D/F. flags the previous-day punch and the resulting 32h 53m duration as critical" do
      a = described_class.for(bad_request)
      expect(a.effective_at).to eq(at(12, 15, 10))
      expect(a.inside_window?).to be false
      expect(a.projected_worked_minutes).to eq((32 * 60) + 53)
      expect(a.duration_severity).to eq(:critical)
      expect(a.requires_confirmation?).to be true
    end

    it "B/C. accepts a legitimate overnight check-out, judged on the day the applier writes" do
      # proposed_date defaults to the work date; the applier rolls 01:30 past the
      # 19:05 check-in onto 14 Sep — the assessment must judge that same moment.
      req = create(:employee_request, :punch_correction, user: employee, correction_type: "wrong_check_out_time",
                   requested_for_date: work_date, proposed_date: Date.new(2026, 9, 14), proposed_time: "01:30")
      a = described_class.for(req)
      expect(a.effective_at).to eq(at(14, 1, 30))
      expect(a.inside_window?).to be true
      expect(a.projected_worked_minutes).to eq(385)
      expect(a.duration_severity).to be_nil
      expect(a.requires_confirmation?).to be false
    end

    it "judges the reviewer's approved_time when given" do
      a = described_class.for(bad_request, time_str: "19:00")
      expect(a.effective_at).to eq(at(12, 19))
      expect(a.inside_window?).to be false
    end

    it "requires confirmation for an in-window punch whose duration is abnormal" do
      record.update_columns(check_in_at: at(13, 0, 30), check_out_at: at(13, 1, 0))
      req = create(:employee_request, :punch_correction, user: employee, correction_type: "wrong_check_out_time",
                   requested_for_date: work_date, proposed_time: "23:30")
      a = described_class.for(req)
      expect(a.inside_window?).to be true
      expect(a.projected_worked_minutes).to eq(23 * 60)
      expect(a.duration_severity).to eq(:suspicious)
      expect(a.requires_confirmation?).to be true
    end
  end

  describe "Requests::Approver gate" do
    it "G. rejects an out-of-window approval without explicit confirmation and changes nothing" do
      result = Requests::Approver.approve(request: bad_request, reviewed_by: manager)

      expect(result).not_to be_success
      expect(result.error).to eq(I18n.t("requests.errors.attendance_window_confirmation_required"))
      expect(bad_request.reload).to be_pending
      expect(record.reload.check_in_at).to eq(at(13, 19, 5))
      expect(record.worked_minutes).to eq(298)
    end

    it "G. treats a non-true confirmation value as missing" do
      result = Requests::Approver.approve(request: bad_request, reviewed_by: manager, confirm_out_of_window: "0")
      expect(result).not_to be_success
    end

    it "H. approves once the reviewer explicitly confirms, keeping the datetime exactly as entered" do
      result = Requests::Approver.approve(request: bad_request, reviewed_by: manager, confirm_out_of_window: "1")

      expect(result).to be_success
      expect(bad_request.reload).to be_approved
      expect(bad_request.proposed_date).to eq(Date.new(2026, 9, 12))
      expect(bad_request.proposed_time).to eq("15:10")
      record.reload
      expect(record.check_in_at).to eq(at(12, 15, 10)) # not normalized / moved
      expect(record.worked_minutes).to eq((32 * 60) + 53)
    end

    it "F. flags the resulting >24h duration for review without modifying the record" do
      Requests::Approver.approve(request: bad_request, reviewed_by: manager, confirm_out_of_window: true)
      record.reload
      expect(record.duration_severity).to eq(:critical)
      expect(record).not_to be_deleted
    end

    it "records the window check and confirmation in the audit log" do
      Requests::Approver.approve(request: bad_request, reviewed_by: manager, confirm_out_of_window: true)
      window = AuditLog.where(auditable: bad_request, action: "approve").last.metadata["attendance_window"]
      expect(window).to include("inside_window" => false, "confirmed_by_reviewer" => true,
                                "duration_severity" => "critical", "resulting_duration_severity" => "critical",
                                "resulting_worked_minutes" => (32 * 60) + 53)
    end

    it "I. approves an in-window correction without any confirmation (existing behavior)" do
      req = create(:employee_request, :punch_correction, user: employee, correction_type: "wrong_check_out_time",
                   requested_for_date: work_date, proposed_date: Date.new(2026, 9, 14), proposed_time: "01:30")
      result = Requests::Approver.approve(request: req, reviewed_by: manager)

      expect(result).to be_success
      expect(record.reload.check_out_at).to eq(at(14, 1, 30))
      expect(record.worked_minutes).to eq(385)
      expect(record.duration_severity).to be_nil
    end

    it "no confirmation needed when the reviewer corrects the time back into the window" do
      in_window = create(:employee_request, :punch_correction, user: employee, correction_type: "wrong_check_in_time",
                         requested_for_date: work_date, proposed_time: "15:10") # 13 Sep 15:10 → outside
      result = Requests::Approver.approve(request: in_window, reviewed_by: manager, approved_time: "19:00")
      expect(result).to be_success
      expect(record.reload.check_in_at).to eq(at(13, 19))
    end
  end

  describe Attendance::DurationCheck do
    it "classifies against the business thresholds (defaults 16h / 24h)" do
      expect(described_class.severity(16 * 60, business: business)).to be_nil
      expect(described_class.severity((16 * 60) + 1, business: business)).to eq(:suspicious)
      expect(described_class.severity(24 * 60, business: business)).to eq(:suspicious)
      expect(described_class.severity((24 * 60) + 1, business: business)).to eq(:critical)
      expect(described_class.severity(nil, business: business)).to be_nil
    end

    it "honours configured thresholds" do
      business.update!(attendance_suspicious_duration_hours: 12, attendance_critical_duration_hours: 14)
      expect(described_class.severity(13 * 60, business: business)).to eq(:suspicious)
      expect(described_class.severity(15 * 60, business: business)).to eq(:critical)
    end
  end

  describe "Business duration thresholds" do
    it "defaults to 16 and 24 hours" do
      expect(business.attendance_suspicious_duration_hours).to eq(16)
      expect(business.attendance_critical_duration_hours).to eq(24)
    end

    it "requires the critical threshold to exceed the suspicious one" do
      business.assign_attributes(attendance_suspicious_duration_hours: 20, attendance_critical_duration_hours: 18)
      expect(business).not_to be_valid
      expect(business.errors[:attendance_critical_duration_hours]).to be_present
    end
  end
end
