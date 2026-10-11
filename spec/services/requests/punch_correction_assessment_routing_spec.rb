require "rails_helper"

# Pilot 10 — Punch Correction, M3: Requests::PunchCorrectionAssessment reads the
# attendance facts only through Requests::PunchCorrectionEffects.correction_facts.
# Pins (1) what each caller hands the contract (request, field, effective moment,
# baseline), (2) parity with the pre-M3 direct reads (Attendance::PunchWindow,
# AttendanceRecord, Attendance::RecordRecomputer on a copy, Attendance::DurationCheck
# — recomputed here as an oracle), and (3) that only plain values reach Workforce.
# correction_approved / correction_cancelled stay unrouted until M4.
RSpec.describe Requests::PunchCorrectionAssessment do
  around { |ex| travel_to(Time.zone.local(2026, 7, 15, 12, 0, 0)) { ex.run } }

  let(:contract) { Requests::PunchCorrectionEffects }
  let(:business) { create(:business) }
  let(:tz)       { ActiveSupport::TimeZone[business.timezone] }
  let(:branch)   { create(:branch, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:reviewer) { create(:user, :owner, business: business) }
  let(:shift) do
    create(:shift, :fixed_time, business: business, name: "Morning",
                                start_time: Time.zone.parse("09:00"), end_time: Time.zone.parse("17:00"))
  end
  let!(:assignment) do
    create(:shift_assignment, user: employee, branch: branch, shift: shift, effective_from: Date.new(2026, 1, 1))
  end
  let(:day) { Date.new(2026, 6, 8) }

  def at(hour, minute = 0, date: day) = tz.local(date.year, date.month, date.day, hour, minute)

  def attendance(check_in: at(9, 40), check_out: at(15, 0))
    @attendance ||= create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment,
                                               date: day, work_date: day, check_in_at: check_in, check_out_at: check_out,
                                               check_in_source: "device", check_out_source: "device",
                                               worked_minutes: check_out ? ((check_out - check_in) / 60).to_i : nil)
  end

  def correction(type, time, date: day, status: :pending)
    build(:employee_request, :punch_correction, status, user: employee, requested_for_date: day, correction_type: type,
                                                        proposed_time: time, proposed_date: date)
      .tap { |req| req.save!(validate: false) }
  end

  def spy_on_facts = allow(contract).to receive(:correction_facts).and_call_original

  # The pre-M3 reads, computed directly from Attendance & Payroll.
  def oracle(req, effective_at, original_in, original_out)
    window = Attendance::PunchWindow.for(user: req.user, work_date: req.requested_for_date)
    record = AttendanceRecord.find_by(user: req.user, work_date: req.requested_for_date)
    copy = nil
    if record && effective_at
      copy = record.dup
      copy.check_in_at  = req.correction_field == :check_in  ? effective_at : original_in
      copy.check_out_at = req.correction_field == :check_out ? effective_at : original_out
      Attendance::RecordRecomputer.recompute!(copy)
    end
    minutes = copy&.worked_minutes
    { inside_window: window.cover?(effective_at), shift_name: window.shift&.name,
      shift_starts_at: window.shift_starts_at, shift_ends_at: window.shift_ends_at, projected_worked_minutes: minutes,
      duration_severity: Attendance::DurationCheck.severity(minutes, business: req.user.business),
      punch_order_invalid: copy&.check_in_at && copy.check_out_at ? copy.check_out_at < copy.check_in_at : false,
      record_in: record&.check_in_at, record_out: record&.check_out_at }
  end

  def expect_oracle_parity(assessment, original_in:, original_out:)
    expected = oracle(assessment.request, assessment.effective_at, original_in, original_out)
    expect(assessment.inside_window?).to eq(expected[:inside_window])
    expect(assessment.window.shift&.name).to eq(expected[:shift_name])
    expect(assessment.window.shift_starts_at).to eq(expected[:shift_starts_at])
    expect(assessment.window.shift_ends_at).to eq(expected[:shift_ends_at])
    expect(assessment.projected_worked_minutes).to eq(expected[:projected_worked_minutes])
    expect(assessment.duration_severity).to eq(expected[:duration_severity])
    expect(assessment.punch_order_invalid?).to eq(assessment.check_out_not_after_check_in? || expected[:punch_order_invalid])
    expected
  end

  describe "arguments handed to correction_facts" do
    before { spy_on_facts }

    it "a pending check-in correction: the request, :check_in, the proposal's moment, no baseline — one call" do
      attendance
      req = correction("wrong_check_in_time", "09:00")

      assessment = described_class.for(req)
      assessment.inside_window?
      assessment.projected_worked_minutes
      assessment.duration_severity

      expect(contract).to have_received(:correction_facts).once
        .with(request: req, field: :check_in, effective_at: at(9), baseline: nil)
    end

    it "the reviewer's date / time override the proposal" do
      attendance
      req = correction("wrong_check_out_time", "15:00")

      described_class.for(req, date: day + 1, time_str: "01:30").inside_window?

      expect(contract).to have_received(:correction_facts)
        .with(request: req, field: :check_out, effective_at: at(1, 30, date: day + 1), baseline: nil)
    end

    it "an applied correction: baseline is the request's snapshot (punches and sources)" do
      attendance(check_in: at(9, 0))
      req = correction("wrong_check_in_time", "09:00", status: :approved)
      req.update_columns(approved_punch_at: at(9, 0), original_check_in_at: at(9, 40), original_check_out_at: at(15, 0),
                         original_check_in_source: "device", original_check_out_source: "mobile")

      described_class.for(req).inside_window?

      expect(contract).to have_received(:correction_facts).with(
        request: req, field: :check_in, effective_at: at(9, 0),
        baseline: contract::Snapshot.new(check_in_at: at(9, 40), check_out_at: at(15, 0),
                                         check_in_source: "device", check_out_source: "mobile")
      )
    end

    it "a legacy approval (no approved_punch_at): effective_at is still derived from the snapshot alone, then judged" do
      attendance(check_in: at(9, 0))
      req = correction("wrong_check_in_time", "09:00", status: :approved)
      req.update_columns(approved_punch_at: nil, original_check_in_at: at(9, 40), original_check_out_at: at(15, 0),
                         original_check_in_source: "device", original_check_out_source: "device")
      legacy = Requests::PunchCorrectionApplier.legacy_applied_punch_at(request: req, check_in_at: at(9, 40),
                                                                         check_out_at: at(15, 0))

      assessment = described_class.for(req)
      expect(assessment.effective_at).to eq(legacy)
      assessment.inside_window?

      expect(contract).to have_received(:correction_facts)
        .with(request: req, field: :check_in, effective_at: legacy, baseline: an_instance_of(contract::Snapshot))
    end

    it "is lazy: building an assessment alone does not call the contract" do
      described_class.for(correction("wrong_check_in_time", "09:00"))
      expect(contract).not_to have_received(:correction_facts)
    end
  end

  describe "callers route through the contract" do
    before { spy_on_facts }

    it "EmployeeRequest#check_out_after_check_in (create validation)" do
      attendance
      req = build(:employee_request, :punch_correction, user: employee, requested_for_date: day,
                                                        correction_type: "wrong_check_out_time", proposed_time: "09:30",
                                                        proposed_date: day)

      expect(req).not_to be_valid
      expect(req.errors[:base]).to include(I18n.t("requests.errors.check_out_not_after_check_in"))
      expect(contract).to have_received(:correction_facts)
        .with(request: req, field: :check_out, effective_at: at(9, 30), baseline: nil)
    end

    it "Requests::Approver#approve_punch_correction (the final reviewer moment)" do
      attendance
      req = correction("wrong_check_in_time", "09:00")

      result = Requests::Approver.approve(request: req, reviewed_by: reviewer, approved_at: "#{day.iso8601}T09:05")

      expect(result).to be_success
      expect(contract).to have_received(:correction_facts)
        .with(request: req, field: :check_in, effective_at: at(9, 5), baseline: nil)
    end

    it "Requests::Approver refuses the confirmation gate from the routed facts, unchanged" do
      attendance
      req = correction("wrong_check_in_time", "09:00", date: day - 3)

      result = Requests::Approver.approve(request: req, reviewed_by: reviewer)

      expect(result).not_to be_success
      expect(result.error).to eq(I18n.t("requests.errors.attendance_window_confirmation_required"))
      expect(req.reload).to be_pending
    end

    it "the approve audit's attendance_window metadata keeps its keys and values" do
      attendance
      req = correction("wrong_check_in_time", "09:00")

      Requests::Approver.approve(request: req, reviewed_by: reviewer)

      window = AuditLog.where(auditable: req, action: "approve").last.metadata["attendance_window"]
      expect(window).to include("final_punch_date" => day.iso8601, "final_punch_time" => "09:00",
                                "effective_at" => at(9).iso8601, "inside_window" => true,
                                "projected_worked_minutes" => 360, "duration_severity" => nil,
                                "confirmed_by_reviewer" => false)
    end

    it "raises NotRegistered (never silently skips the checks) when no handler is registered" do
      original = contract.instance_variable_get(:@handler)
      contract.instance_variable_set(:@handler, nil)
      expect { described_class.for(correction("wrong_check_in_time", "09:00")).inside_window? }
        .to raise_error(contract::NotRegistered)
    ensure
      contract.instance_variable_set(:@handler, original)
    end
  end

  describe "parity with the pre-M3 direct reads" do
    it "check-in correction inside the window" do
      record = attendance
      a = described_class.for(correction("wrong_check_in_time", "09:00"))
      expected = expect_oracle_parity(a, original_in: record.check_in_at, original_out: record.check_out_at)
      expect([ a.original_check_in_at, a.original_check_out_at ]).to eq([ expected[:record_in], expected[:record_out] ])
      expect(a.projected_worked_minutes).to eq(360)
    end

    it "check-out correction on another date (outside the window, confirmation required)" do
      record = attendance
      a = described_class.for(correction("wrong_check_out_time", "15:00", date: day + 3))
      expect_oracle_parity(a, original_in: record.check_in_at, original_out: record.check_out_at)
      expect(a.requires_confirmation?).to be(true)
    end

    it "overnight check-out with an abnormal duration" do
      record = attendance
      a = described_class.for(correction("wrong_check_out_time", "03:00", date: day + 1))
      expect_oracle_parity(a, original_in: record.check_in_at, original_out: record.check_out_at)
      expect(a.duration_severity).to be_present
    end

    it "check-in correction after the check-out: punch order invalid, same message" do
      record = attendance
      a = described_class.for(correction("wrong_check_in_time", "16:00"), time_str: "16:00", date: day)
      a2 = described_class.for(correction("wrong_check_in_time", "15:30"), date: day, time_str: "15:30")
      expect_oracle_parity(a, original_in: record.check_in_at, original_out: record.check_out_at)
      expect_oracle_parity(a2, original_in: record.check_in_at, original_out: record.check_out_at)
      expect(a.punch_order_invalid?).to be(true)
      expect(a.punch_order_error).to eq(I18n.t("requests.errors.check_out_before_check_in"))
    end

    it "check-out correction not after the check-in: invalid with its own message" do
      record = attendance
      a = described_class.for(correction("wrong_check_out_time", "09:40"))
      expect_oracle_parity(a, original_in: record.check_in_at, original_out: record.check_out_at)
      expect(a.punch_order_invalid?).to be(true)
      expect(a.punch_order_error).to eq(I18n.t("requests.errors.check_out_not_after_check_in"))
    end

    it "missing other punch: nothing projected, order not judged" do
      record = attendance(check_out: nil)
      a = described_class.for(correction("wrong_check_in_time", "09:00"))
      expect_oracle_parity(a, original_in: record.check_in_at, original_out: nil)
      expect(a.projected_worked_minutes).to be_nil
      expect(a.punch_order_invalid?).to be(false)
    end

    it "no attendance record" do
      a = described_class.for(correction("missing_check_in", "09:00"))
      expect_oracle_parity(a, original_in: nil, original_out: nil)
      expect([ a.original_check_in_at, a.original_check_out_at, a.punch_order_invalid? ]).to eq([ nil, nil, false ])
    end

    it "an applied correction judged against its snapshot, not the corrected record" do
      attendance(check_in: at(9, 0))
      req = correction("wrong_check_in_time", "09:00", status: :approved)
      req.update_columns(approved_punch_at: at(9, 0), original_check_in_at: at(9, 40), original_check_out_at: at(15, 0),
                         original_check_in_source: "device", original_check_out_source: "device")
      a = described_class.for(req)
      expect_oracle_parity(a, original_in: at(9, 40), original_out: at(15, 0))
      expect(a.original_check_in_at).to eq(at(9, 40))
    end
  end

  describe "only plain values reach Workforce" do
    it "the window is a Workforce struct: work date, shift name / start / end" do
      attendance
      window = described_class.for(correction("wrong_check_in_time", "09:00")).window

      expect(window).to be_a(described_class::Window)
      expect(window.shift).to be_a(described_class::Shift)
      expect(window).to have_attributes(work_date: day, shift_starts_at: at(9), shift_ends_at: at(17))
      expect(window.shift.name).to eq("Morning")
    end

    it "an hour-based shift carries its required hours and no start / end" do
      hour_based = create(:shift, :hour_based, business: business, name: "Flexible", required_hours: 7.5)
      assignment.update!(shift: hour_based)
      window = described_class.for(correction("wrong_check_in_time", "09:00")).window

      expect(window.shift).to have_attributes(name: "Flexible")
      expect(window.shift.required_hours.to_f).to eq(7.5)
      expect([ window.shift_starts_at, window.shift_ends_at ]).to eq([ nil, nil ])
    end

    it "without an assigned shift, window.shift is nil" do
      assignment.destroy!
      window = described_class.for(correction("wrong_check_in_time", "09:00")).window
      expect(window.shift).to be_nil
      expect(window.work_date).to eq(day)
    end

    it "the assessment exposes no attendance record or projected record" do
      a = described_class.for(correction("wrong_check_in_time", "09:00"))
      expect(a).not_to respond_to(:record)
      expect(a).not_to respond_to(:projected_record)
    end
  end
end
