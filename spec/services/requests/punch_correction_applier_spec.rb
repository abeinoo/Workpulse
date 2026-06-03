require "rails_helper"

RSpec.describe Requests::PunchCorrectionApplier do
  let(:business) { create(:business, timezone: "UTC") }
  let(:branch)   { create(:branch, business: business) }
  let(:user)     { create(:user, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }
  let(:work_date) { Date.current - 1.day }

  # UTC times — the business timezone is "UTC" in this spec, so check_in at 09:00 UTC.
  let(:check_in_utc) { Time.utc(work_date.year, work_date.month, work_date.day, 9, 0, 0) }

  let(:open_record) do
    create(:attendance_record,
           user:           user,
           branch:         branch,
           shift:          shift,
           date:           work_date,
           work_date:      work_date,
           check_in_at:    check_in_utc,
           check_out_at:   nil,
           status:         "incomplete",
           worked_minutes: nil)
  end

  let(:checked_out_record) do
    create(:attendance_record, :checked_out,
           user:        user,
           branch:      branch,
           shift:       shift,
           date:        work_date,
           work_date:   work_date,
           check_in_at: check_in_utc)
  end

  def build_request(correction_type:, proposed_time_str: "17:00", record_date: work_date)
    create(:employee_request, :punch_correction,
           user:               user,
           correction_type:    correction_type,
           requested_for_date: record_date,
           proposed_time:      proposed_time_str,
           status:             :approved,
           reviewed_at:        Time.current)
  end

  # ──────────────────────────────────────────────────────────────
  # missing_check_out — fills in check_out_at
  # ──────────────────────────────────────────────────────────────
  describe "missing_check_out correction" do
    let!(:record) { open_record }
    let(:request) { build_request(correction_type: "missing_check_out", proposed_time_str: "17:00") }

    it "returns success" do
      result = described_class.call(request: request)
      expect(result).to be_success
    end

    it "sets check_out_at to the proposed time on the work_date" do
      described_class.call(request: request)
      expect(record.reload.check_out_at.hour).to eq(17)
      expect(record.reload.check_out_at.min).to eq(0)
    end

    it "sets check_out_source to admin_manual" do
      described_class.call(request: request)
      expect(record.reload.check_out_source).to eq("admin_manual")
    end

    it "recomputes worked_minutes" do
      described_class.call(request: request)
      expect(record.reload.worked_minutes).to eq(480) # 09:00 → 17:00 = 8h
    end

    it "changes status from incomplete to present" do
      described_class.call(request: request)
      expect(record.reload.status).to eq("present")
    end

    it "snapshots original_check_in_at onto the request" do
      original_check_in = record.check_in_at
      described_class.call(request: request)
      expect(request.reload.original_check_in_at).to be_within(1.second).of(original_check_in)
    end

    it "snapshots original_check_out_at as nil onto the request" do
      described_class.call(request: request)
      expect(request.reload.original_check_out_at).to be_nil
    end
  end

  # ──────────────────────────────────────────────────────────────
  # wrong_check_out_time — corrects an existing check_out_at
  # ──────────────────────────────────────────────────────────────
  describe "wrong_check_out_time correction" do
    let!(:record) { checked_out_record }
    let(:request) { build_request(correction_type: "wrong_check_out_time", proposed_time_str: "16:45") }

    it "returns success" do
      expect(described_class.call(request: request)).to be_success
    end

    it "updates check_out_at to the corrected time" do
      described_class.call(request: request)
      expect(record.reload.check_out_at.hour).to eq(16)
      expect(record.reload.check_out_at.min).to eq(45)
    end

    it "recomputes worked_minutes from the new checkout time" do
      described_class.call(request: request)
      expect(record.reload.worked_minutes).to eq(465) # 09:00 → 16:45 = 7h45m
    end
  end

  # ──────────────────────────────────────────────────────────────
  # wrong_check_in_time — corrects an existing check_in_at
  # ──────────────────────────────────────────────────────────────
  describe "wrong_check_in_time correction" do
    let!(:record) { checked_out_record }
    let(:request) { build_request(correction_type: "wrong_check_in_time", proposed_time_str: "08:45") }

    it "returns success" do
      expect(described_class.call(request: request)).to be_success
    end

    it "updates check_in_at to the corrected time" do
      described_class.call(request: request)
      expect(record.reload.check_in_at.hour).to eq(8)
      expect(record.reload.check_in_at.min).to eq(45)
    end

    it "sets check_in_source to admin_manual" do
      described_class.call(request: request)
      expect(record.reload.check_in_source).to eq("admin_manual")
    end
  end

  # ──────────────────────────────────────────────────────────────
  # approved_time overrides proposed_time
  # ──────────────────────────────────────────────────────────────
  describe "approved_time takes precedence over proposed_time" do
    let!(:record) { open_record }
    let(:request) do
      create(:employee_request, :punch_correction,
             user:               user,
             correction_type:    "missing_check_out",
             requested_for_date: work_date,
             proposed_time:      "17:00",
             approved_time:      "16:45",
             status:             :approved,
             reviewed_at:        Time.current)
    end

    it "uses approved_time, not proposed_time" do
      described_class.call(request: request)
      expect(record.reload.check_out_at.hour).to eq(16)
      expect(record.reload.check_out_at.min).to eq(45)
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Overnight: proposed_date carries the punch to the next calendar day
  # ──────────────────────────────────────────────────────────────
  describe "overnight check-out (proposed_date = next day)" do
    let!(:record) { open_record }
    let(:request) do
      create(:employee_request, :punch_correction,
             user:               user,
             correction_type:    "missing_check_out",
             requested_for_date: work_date,            # business/work day
             proposed_date:      work_date + 1.day,    # actual punch is next calendar day
             proposed_time:      "04:00",
             status:             :approved,
             reviewed_at:        Time.current)
    end

    it "stores the check-out on the day after the work_date" do
      described_class.call(request: request)
      out = record.reload.check_out_at.in_time_zone(business.timezone_object)
      expect(out.to_date).to eq(work_date + 1.day)
      expect(out.hour).to eq(4)
    end

    it "recomputes worked_minutes across midnight" do
      described_class.call(request: request)
      # 09:00 day 1 → 04:00 day 2 = 19h = 1140 minutes
      expect(record.reload.worked_minutes).to eq(1140)
    end
  end

  # ──────────────────────────────────────────────────────────────
  # No attendance record found
  # ──────────────────────────────────────────────────────────────
  describe "when no attendance record exists for the date" do
    let(:request) { build_request(correction_type: "missing_check_out", record_date: Date.current - 30.days) }

    it "returns failure" do
      result = described_class.call(request: request)
      expect(result).not_to be_success
      expect(result.error).to include("No attendance record")
    end

    it "does not change any attendance records" do
      expect { described_class.call(request: request) }.not_to change(AttendanceRecord, :count)
    end
  end

  # ──────────────────────────────────────────────────────────────
  # Payroll integration
  # ──────────────────────────────────────────────────────────────
  describe "payroll propagation" do
    let!(:record) { open_record }
    let(:request) { build_request(correction_type: "missing_check_out") }

    it "calls Payroll::PunchCorrectionApplier with the updated record" do
      allow(Payroll::PunchCorrectionApplier).to receive(:call)
      described_class.call(request: request)
      expect(Payroll::PunchCorrectionApplier).to have_received(:call).with(
        request: request,
        record:  record
      )
    end
  end
end
