require "rails_helper"

RSpec.describe Attendance::AdjustmentService do
  let(:business) { create(:business, timezone: "UTC") }
  let(:branch)   { create(:branch, business: business) }
  let(:manager)  { create(:user, :branch_manager, business: business) }
  let!(:record)  do
    create(:attendance_record, :checked_out, branch: branch,
           check_in_at:  Time.current.change(hour: 9, min: 30, sec: 0),
           check_out_at: Time.current.change(hour: 17, min: 0, sec: 0))
  end

  def call(params)
    described_class.call(record: record, adjusted_by: manager, params: params)
  end

  describe "check_in_at adjustment" do
    let(:new_check_in) { record.check_in_at - 30.minutes }

    it "returns success" do
      result = call(check_in_at: new_check_in, reason: "Employee was on time")
      expect(result).to be_success
    end

    it "updates check_in_at on the record" do
      call(check_in_at: new_check_in, reason: "Employee was on time")
      expect(record.reload.check_in_at).to be_within(1.second).of(new_check_in)
    end

    it "creates one AttendanceAdjustment audit entry" do
      expect {
        call(check_in_at: new_check_in, reason: "Employee was on time")
      }.to change(AttendanceAdjustment, :count).by(1)
    end

    it "records field_name, old_value, new_value, adjusted_by" do
      call(check_in_at: new_check_in, reason: "Correcting the record")
      adj = AttendanceAdjustment.last
      expect(adj.field_name).to eq("check_in_at")
      expect(adj.adjusted_by).to eq(manager)
      expect(adj.old_value).to be_present
      expect(adj.new_value).to be_present
    end

    it "stores the reason on the audit entry" do
      call(check_in_at: new_check_in, reason: "Doctor confirmed on time")
      expect(AttendanceAdjustment.last.reason).to eq("Doctor confirmed on time")
    end

    it "recomputes late_minutes after adjusting check_in to on-time" do
      on_time = record.shift_assignment.shift.start_time
      new_time = record.check_in_at.change(hour: on_time.hour, min: on_time.min, sec: 0)
      call(check_in_at: new_time, reason: "On time")
      expect(record.reload.late_minutes).to eq(0)
    end

    it "recomputes worked_minutes when both in and out are set" do
      call(check_in_at: new_check_in, reason: "Was earlier")
      expected = ((record.reload.check_out_at - record.reload.check_in_at) / 60).to_i
      expect(record.reload.worked_minutes).to eq(expected)
    end
  end

  describe "check_out_at adjustment" do
    it "updates the check-out time" do
      new_out = record.check_out_at + 45.minutes
      call(check_out_at: new_out, reason: "Stayed late")
      expect(record.reload.check_out_at).to be_within(1.second).of(new_out)
    end

    it "creates an audit entry for check_out_at" do
      expect {
        call(check_out_at: record.check_out_at + 30.minutes, reason: "Forgot to check out")
      }.to change(AttendanceAdjustment, :count).by(1)
    end
  end

  describe "status is always auto-derived (never user-editable)" do
    it "ignores a status param and rejects the call when no time fields changed" do
      result = call(status: "present", reason: "Trying to manually set status")
      expect(result).not_to be_success
      expect(result.error).to include("No changes detected")
    end

    it "does not create a status audit entry even when status param is passed alongside a time change" do
      call(check_in_at: record.check_in_at - 30.minutes, status: "late", reason: "Fix")
      expect(AttendanceAdjustment.find_by(field_name: "status")).to be_nil
    end

    it "derives status as late when check_in is adjusted to a late time" do
      shift_start = record.shift_assignment.shift.start_time
      late_time   = record.check_in_at.change(hour: shift_start.hour, min: shift_start.min + 20)
      call(check_in_at: late_time, reason: "Corrected entry")
      expect(record.reload.status).to eq("late")
    end

    it "reverts status to incomplete when check_out is cleared" do
      call(check_out_at: "", reason: "Checkout was entered in error")
      expect(record.reload.status).to eq("incomplete").or eq("late")
      expect(record.reload.check_out_at).to be_nil
      expect(record.reload.worked_minutes).to be_nil
    end
  end

  describe "multiple field changes" do
    it "creates one audit entry per changed field" do
      expect {
        call(
          check_in_at:  record.check_in_at - 15.minutes,
          check_out_at: record.check_out_at + 30.minutes,
          reason:       "Full correction"
        )
      }.to change(AttendanceAdjustment, :count).by(2)
    end
  end

  describe "audit entry immutability" do
    it "cannot be updated after creation" do
      call(check_in_at: record.check_in_at - 10.minutes, reason: "Fix")
      adj = AttendanceAdjustment.last
      expect { adj.update!(reason: "tampered") }.to raise_error(ActiveRecord::RecordNotSaved)
    end

    it "cannot be destroyed" do
      call(check_in_at: record.check_in_at - 10.minutes, reason: "Fix")
      adj = AttendanceAdjustment.last
      expect { adj.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
    end
  end

  describe "validation failures" do
    it "returns failure when reason is blank" do
      result = call(check_in_at: record.check_in_at - 10.minutes, reason: "")
      expect(result).not_to be_success
      expect(result.error).to eq("A reason is required for attendance adjustments")
    end

    it "does not create any audit entries on blank reason" do
      expect {
        call(check_in_at: record.check_in_at - 10.minutes, reason: "")
      }.not_to change(AttendanceAdjustment, :count)
    end

    it "returns failure when no fields actually changed" do
      result = call(check_in_at: record.check_in_at, reason: "No change")
      expect(result).not_to be_success
    end

    it "does not persist changes on failure" do
      original_in = record.check_in_at
      call(check_in_at: record.check_in_at, reason: "No change")
      expect(record.reload.check_in_at).to be_within(1.second).of(original_in)
    end
  end
end
