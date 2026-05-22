require "rails_helper"

RSpec.describe Attendance::PunchService do
  # Business with Asia/Riyadh timezone (UTC+3) and day starting at 06:00 local
  let(:business) { create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 6) }
  let(:branch)   { create(:branch, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }
  let(:employee) { create(:user, :employee, business: business) }
  let!(:assignment) do
    create(:shift_assignment,
           user:           employee,
           shift:          shift,
           branch:         branch,
           effective_from: 2.weeks.ago.to_date)
  end

  # Punch at a local Riyadh time string, e.g. "2026-05-17 09:05:00 +03:00"
  def punch(time_str)
    described_class.call(
      employee:   employee,
      punched_at: Time.zone.parse(time_str),
      business:   business
    )
  end

  # ───── First punch → check_in ──────────────────────────────────────────────

  describe "first punch of the work day" do
    it "creates an attendance record and returns check_in action" do
      result = punch("2026-05-17 09:05:00 +03:00")
      expect(result.success?).to be true
      expect(result.action).to eq("check_in")
      expect(result.record).to be_persisted
    end

    it "sets check_in_at to the punch timestamp" do
      result = punch("2026-05-17 09:05:00 +03:00")
      expect(result.record.check_in_at).to be_within(1.second).of(
        Time.zone.parse("2026-05-17 09:05:00 +03:00")
      )
    end

    it "leaves check_out_at nil" do
      result = punch("2026-05-17 09:05:00 +03:00")
      expect(result.record.check_out_at).to be_nil
    end

    it "creates a BiometricPunchLog with action check_in" do
      result = punch("2026-05-17 09:05:00 +03:00")
      expect(result.log.action).to eq("check_in")
    end

    it "marks attendance as late when punch is after shift start" do
      # Shift starts at 09:00; punch at 09:15 → late
      result = punch("2026-05-17 09:15:00 +03:00")
      expect(result.record.late_minutes).to be > 0
      expect(result.record.status).to eq("late")
    end
  end

  # ───── Second punch → check_out ───────────────────────────────────────────

  describe "second punch (after check_in)" do
    before { punch("2026-05-17 09:00:00 +03:00") }

    it "sets check_out and returns check_out action" do
      result = punch("2026-05-17 17:02:00 +03:00")
      expect(result.success?).to be true
      expect(result.action).to eq("check_out")
      expect(result.record.check_out_at).to be_within(1.second).of(
        Time.zone.parse("2026-05-17 17:02:00 +03:00")
      )
    end

    it "calculates worked_minutes" do
      result = punch("2026-05-17 17:00:00 +03:00")
      expect(result.record.worked_minutes).to be_within(2).of(480) # 8h = 480m
    end
  end

  # ───── Multiple punches — keeps earliest check_in and latest check_out ────

  describe "multiple punches on the same work day" do
    it "keeps the earliest punch as check_in" do
      punch("2026-05-17 09:05:00 +03:00")
      result = punch("2026-05-17 08:55:00 +03:00") # earlier arrives after
      expect(result.action).to eq("check_in_updated")
      expect(result.record.check_in_at).to be_within(1.second).of(
        Time.zone.parse("2026-05-17 08:55:00 +03:00")
      )
    end

    it "updates check_out to the latest punch" do
      punch("2026-05-17 09:01:00 +03:00")
      punch("2026-05-17 17:02:00 +03:00")
      result = punch("2026-05-17 17:10:00 +03:00") # later punch
      expect(result.action).to eq("check_out")
      expect(result.record.check_out_at).to be_within(1.second).of(
        Time.zone.parse("2026-05-17 17:10:00 +03:00")
      )
    end

    it "does not regress check_out when an older punch arrives late" do
      punch("2026-05-17 09:01:00 +03:00")
      punch("2026-05-17 17:10:00 +03:00")
      result = punch("2026-05-17 17:05:00 +03:00") # older than current check_out
      expect(result.action).to eq("rejected_spam") # treated as duplicate/old
    end
  end

  # ───── Spam / duplicate protection ────────────────────────────────────────

  describe "spam protection (SPAM_WINDOW = 60s)" do
    it "rejects a punch within 60 seconds of a previous logged punch" do
      punch("2026-05-17 09:01:00 +03:00")
      result = punch("2026-05-17 09:01:30 +03:00") # 30s later
      expect(result.action).to eq("rejected_spam")
      expect(result.success?).to be true # graceful rejection
    end

    it "allows a punch after the spam window has passed" do
      punch("2026-05-17 09:01:00 +03:00")
      result = punch("2026-05-17 09:02:30 +03:00") # 90s later
      expect(result.action).not_to eq("rejected_spam")
    end

    it "logs rejected_spam punches" do
      punch("2026-05-17 09:01:00 +03:00")
      result = punch("2026-05-17 09:01:15 +03:00")
      expect(result.log.action).to eq("rejected_spam")
    end
  end

  # ───── Missing shift assignment ────────────────────────────────────────────

  describe "employee with no active shift assignment" do
    before { assignment.destroy }

    it "returns failure with rejected_no_assignment action" do
      result = punch("2026-05-17 09:05:00 +03:00")
      expect(result.success?).to be false
      expect(result.action).to eq("rejected_no_assignment")
    end

    it "does not create an attendance record" do
      expect { punch("2026-05-17 09:05:00 +03:00") }.not_to change(AttendanceRecord, :count)
    end

    it "logs the rejection" do
      result = punch("2026-05-17 09:05:00 +03:00")
      expect(result.log.action).to eq("rejected_no_assignment")
    end
  end

  # ───── Business day boundary ───────────────────────────────────────────────

  describe "business day boundary (start_hour = 6, timezone = Asia/Riyadh)" do
    it "assigns work_date to previous day for punches before 06:00 local" do
      # 03:00 Riyadh local = 00:00 UTC → before business_day_start_hour (6)
      result = punch("2026-05-17 03:00:00 +03:00")
      expect(result.log.work_date).to eq(Date.new(2026, 5, 16))
    end

    it "assigns work_date to current day for punches at or after 06:00 local" do
      result = punch("2026-05-17 09:00:00 +03:00")
      expect(result.log.work_date).to eq(Date.new(2026, 5, 17))
    end

    it "groups a pre-dawn checkout with the previous day's check_in" do
      # Employee checks in during the evening of May 16
      punch("2026-05-16 22:00:00 +03:00")
      # Employee checks out in the early hours of May 17 (before 06:00)
      result = punch("2026-05-17 02:00:00 +03:00")
      expect(result.action).to eq("check_out")
      expect(result.record.work_date).to eq(Date.new(2026, 5, 16))
    end
  end

  # ───── Overnight shift ────────────────────────────────────────────────────

  describe "overnight shift (22:00–06:00)" do
    let(:shift) do
      create(:shift, :overnight, business: business,
             start_time: Time.zone.parse("22:00"),
             end_time:   Time.zone.parse("06:00"))
    end

    it "creates check_in on the evening punch" do
      result = punch("2026-05-17 22:05:00 +03:00")
      expect(result.action).to eq("check_in")
      expect(result.record.work_date).to eq(Date.new(2026, 5, 17))
    end

    it "creates check_out on the early-morning punch of the next calendar day" do
      punch("2026-05-17 22:05:00 +03:00")
      result = punch("2026-05-18 05:50:00 +03:00") # 05:50 < 06:00 → still work_date 2026-05-17
      expect(result.action).to eq("check_out")
      expect(result.record.work_date).to eq(Date.new(2026, 5, 17))
    end

    it "calculates worked_minutes correctly across midnight" do
      punch("2026-05-17 22:05:00 +03:00")
      result = punch("2026-05-18 05:55:00 +03:00")
      # 7h 50m = 470 minutes
      expect(result.record.worked_minutes).to be_within(2).of(470)
    end
  end

  # ───── Shift assignment resolution ────────────────────────────────────────

  describe "shift assignment resolution" do
    it "sets branch from the shift assignment on check_in" do
      result = punch("2026-05-17 09:00:00 +03:00")
      expect(result.record.branch).to eq(branch)
    end

    it "links the attendance record to the shift assignment" do
      result = punch("2026-05-17 09:00:00 +03:00")
      expect(result.record.shift_assignment).to eq(assignment)
    end

    context "when assignment has expired" do
      # Use 2.days.ago so the assignment is clearly before any work_date the service
      # might compute (business day starts at 06:00 Riyadh time; if tests run in the
      # early-morning UTC window, Date.yesterday is still the active work_date).
      before { assignment.update!(effective_to: 2.days.ago.to_date) }

      it "rejects today's punch as no active assignment" do
        result = described_class.call(
          employee:   employee,
          punched_at: Time.current,
          business:   business
        )
        expect(result.action).to eq("rejected_no_assignment")
      end
    end
  end

  # ───── Device and audit log ───────────────────────────────────────────────

  describe "device attribution" do
    let(:device) { BiometricDevice.create!(business: business, name: "Gate 1") }

    it "records the device on the punch log" do
      result = described_class.call(
        employee:   employee,
        punched_at: Time.zone.parse("2026-05-17 09:00:00 +03:00"),
        business:   business,
        device:     device
      )
      expect(result.log.biometric_device).to eq(device)
    end

    it "records source as biometric on every log entry" do
      result = described_class.call(
        employee:   employee,
        punched_at: Time.zone.parse("2026-05-17 09:00:00 +03:00"),
        business:   business,
        device:     device
      )
      expect(result.log.source).to eq("biometric")
    end
  end

  # ───── Biometric attendance permission ────────────────────────────────────

  describe "biometric attendance permission" do
    context "when employee has biometric attendance disabled" do
      before { employee.update!(allow_biometric_attendance: false) }

      it "rejects the punch immediately without checking shift assignment" do
        result = punch("2026-05-17 09:00:00 +03:00")
        expect(result.success?).to be false
        expect(result.action).to eq("rejected_not_allowed")
      end

      it "does not create an attendance record" do
        expect { punch("2026-05-17 09:00:00 +03:00") }.not_to change(AttendanceRecord, :count)
      end

      it "logs the rejection with source biometric" do
        result = punch("2026-05-17 09:00:00 +03:00")
        expect(result.log.action).to eq("rejected_not_allowed")
        expect(result.log.source).to eq("biometric")
      end
    end

    context "when employee has biometric attendance enabled (default)" do
      it "processes the punch normally" do
        result = punch("2026-05-17 09:00:00 +03:00")
        expect(result.action).to eq("check_in")
      end
    end
  end
end
