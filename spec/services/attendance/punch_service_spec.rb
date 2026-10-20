require "rails_helper"

RSpec.describe Attendance::PunchService do
  # The success-path examples punch at fixed May-2026 timestamps. Freeze "now" to
  # 2026-05-20 and pin the assignment's effective_from to a fixed early date so the
  # assignment is always active on those dates regardless of the real calendar
  # (previously `2.weeks.ago` drifted past the hardcoded punch dates and the
  # service began rejecting every punch as "no active assignment").
  around { |ex| travel_to(Time.zone.local(2026, 5, 20, 12, 0, 0)) { ex.run } }

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
           effective_from: Date.new(2026, 5, 1))
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

  # ───── Mobile check-in + biometric within check-in window → update check-in ──

  describe "biometric punch within CHECK_IN_UPDATE_WINDOW (mobile+biometric scenario)" do
    before { punch("2026-05-17 09:00:00 +03:00") } # simulates mobile check-in

    it "treats a biometric punch within 1 hour (no checkout yet) as check_in_updated" do
      result = punch("2026-05-17 09:05:00 +03:00") # 5 minutes after mobile check-in
      expect(result.action).to eq("check_in_updated")
    end

    it "updates check_in_at to the biometric punch time" do
      result = punch("2026-05-17 09:05:00 +03:00")
      expect(result.record.check_in_at).to be_within(1.second).of(
        Time.zone.parse("2026-05-17 09:05:00 +03:00")
      )
    end

    it "treats a punch beyond 1 hour as checkout when no checkout exists" do
      result = punch("2026-05-17 10:30:00 +03:00") # 1.5 hours after check-in
      expect(result.action).to eq("check_out")
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

  # Scenario 2 from the temporary cross-branch coverage feature: an employee
  # permanently assigned to `branch` also holds a temporary_coverage
  # assignment at `covering_branch` for a specific date. A punch on that date
  # must stamp the covering branch — not the employee's permanent one.
  describe "temporary branch coverage (Scenario 2)" do
    let(:covering_branch)  { create(:branch, business: business) }
    let(:covering_shift) do
      create(:shift, :fixed_time, business: business,
             start_time: Time.zone.parse("15:00"), end_time: Time.zone.parse("23:00"))
    end

    before do
      create(:shift_assignment, :temporary_coverage, user: employee, branch: covering_branch,
             shift: covering_shift, effective_from: Date.new(2026, 5, 17), effective_to: Date.new(2026, 5, 18))
    end

    it "stamps the covering branch on a check-in during the coverage window" do
      result = punch("2026-05-17 15:05:00 +03:00")
      expect(result.success?).to be true
      expect(result.record.branch).to eq(covering_branch)
    end

    it "stamps the covering branch on check-out during the coverage window too" do
      punch("2026-05-17 15:05:00 +03:00")
      result = punch("2026-05-17 23:05:00 +03:00")
      expect(result.action).to eq("check_out")
      expect(result.record.branch).to eq(covering_branch)
    end

    it "resolves back to the permanent branch outside the coverage window" do
      result = punch("2026-05-20 09:05:00 +03:00")
      expect(result.success?).to be true
      expect(result.record.branch).to eq(branch)
    end

    it "does not modify the employee's permanent (regular) shift assignment" do
      expect { punch("2026-05-17 15:05:00 +03:00") }.not_to change { assignment.reload.attributes }
    end
  end

  # ───── Lost first-punch insert (RecordNotUnique) → one retry ──────────────────
  #
  # The genuine two-connection race is in spec/services/attendance/punch_period_lock_spec.rb.
  # Here the first `times` saves really insert the record and then a duplicate of it,
  # so PostgreSQL itself raises the unique violation (aborting the transaction, as in
  # the race) — pinning the rollback, the single retry and the savepoint.
  describe "a lost first-punch insert (RecordNotUnique)" do
    def conflict_on_save(times:)
      calls = 0
      allow_any_instance_of(AttendanceRecord).to receive(:save).and_wrap_original do |original, *args, **kwargs|
        calls += 1
        saved = original.call(*args, **kwargs)
        AttendanceRecord.insert!(original.receiver.attributes.except("id")) if calls <= times
        saved
      end
      -> { calls }
    end

    def logged_actions = BiometricPunchLog.where(employee: employee).pluck(:action)

    it "rolls the failed attempt back and runs the whole punch once more, period guard included" do
      save_calls = conflict_on_save(times: 1)
      allow(PayrollPeriod).to receive(:lock).and_call_original

      result = punch("2026-05-17 09:05:00 +03:00")

      expect(result).to be_success
      expect(result.action).to eq("check_in") # the failed attempt left no record behind to update
      expect(save_calls.call).to eq(2)
      expect(PayrollPeriod).to have_received(:lock).with("FOR SHARE").twice
      expect(AttendanceRecord.where(user: employee).count).to eq(1)
      expect(logged_actions).to eq([ "check_in" ])
      expect(result.log.attendance_record).to eq(result.record)
    end

    it "retries inside a caller's transaction too (a savepoint: never inside an aborted transaction)" do
      conflict_on_save(times: 1)

      result = ActiveRecord::Base.transaction { punch("2026-05-17 09:05:00 +03:00") }

      expect(result.action).to eq("check_in")
      expect(AttendanceRecord.where(user: employee).count).to eq(1)
      expect(logged_actions).to eq([ "check_in" ])
    end

    it "re-raises a second conflict after exactly one retry and persists nothing" do
      save_calls = conflict_on_save(times: 2)

      expect { punch("2026-05-17 09:05:00 +03:00") }.to raise_error(ActiveRecord::RecordNotUnique)

      expect(save_calls.call).to eq(2)
      expect(AttendanceRecord.where(user: employee).count).to eq(0)
      expect(logged_actions).to be_empty
    end
  end
end
