require "rails_helper"

# Pilot 10 M4-2 — Requests::Approver and Requests::Canceller reach the punch
# correction's attendance & payroll effect ONLY through the Workforce contract
# Requests::PunchCorrectionEffects. With a recording handler registered in
# place of Attendance::PunchCorrectionEffects (facts still delegated to it, so
# the assessment works), approval and cancellation write no attendance or
# payroll themselves, persist the snapshot / audit from the plain result, and
# map every refusal and error to the message they have always shown.
RSpec.describe "Punch correction effects routing (approval and cancellation)" do
  around { |ex| travel_to(Time.zone.local(2026, 7, 15, 12, 0, 0)) { ex.run } }

  let(:business) { create(:business) }
  let(:tz)       { ActiveSupport::TimeZone[business.timezone] }
  let(:branch)   { create(:branch, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:reviewer) { create(:user, :owner, business: business) }
  let(:shift) do
    create(:shift, :fixed_time, business: business, start_time: Time.zone.parse("09:00"), end_time: Time.zone.parse("17:00"))
  end
  let!(:assignment) do
    create(:shift_assignment, user: employee, branch: branch, shift: shift, effective_from: Date.new(2026, 1, 1))
  end
  let(:day) { Date.new(2026, 6, 8) }
  let!(:record) do
    create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment, date: day, work_date: day,
                               check_in_at: at(9, 40), check_out_at: at(15), check_in_source: "device",
                               check_out_source: "device", worked_minutes: 320)
  end
  let(:contract) { Requests::PunchCorrectionEffects }
  let(:replaced) do
    contract::Snapshot.new(check_in_at: at(9, 40), check_out_at: at(15), check_in_source: "device", check_out_source: "device")
  end

  def at(hour, minute = 0) = tz.local(day.year, day.month, day.day, hour, minute)

  def correction(type = "wrong_check_in_time", time = "09:00")
    build(:employee_request, :punch_correction, :pending, user: employee, requested_for_date: day, correction_type: type,
                                                          proposed_time: time, proposed_date: day)
      .tap { |req| req.save!(validate: false) }
  end

  def approve(req) = Requests::Approver.approve(request: req, reviewed_by: reviewer, confirm_out_of_window: true)
  def cancel(req)  = Requests::Canceller.cancel(request: req, cancelled_by: reviewer, reason: "routing")
  def audits(req)  = AuditLog.where(auditable: req).order(:id).pluck(:action)

  # A handler that records the write operations and answers with the given
  # results (a value, or a callable that raises); facts are the real ones.
  def recording_handler(approved: nil, cancelled: :reverted)
    calls = []
    handler = Module.new do
      define_singleton_method(:correction_facts) { |**kw| Attendance::PunchCorrectionEffects.correction_facts(**kw) }
      define_singleton_method(:correction_approved) do |**kw|
        calls << [ :approved, kw ]
        approved.respond_to?(:call) ? approved.call : approved
      end
      define_singleton_method(:correction_cancelled) do |**kw|
        calls << [ :cancelled, kw ]
        cancelled.respond_to?(:call) ? cancelled.call : cancelled
      end
    end
    [ handler, calls ]
  end

  def with_handler(handler)
    original = contract.instance_variable_get(:@handler)
    contract.instance_variable_set(:@handler, handler)
    yield
  ensure
    contract.instance_variable_set(:@handler, original)
  end

  def applied(worked_minutes: 360, duration_severity: nil)
    contract::Approval.new(status: :applied, snapshot: replaced, worked_minutes: worked_minutes,
                           duration_severity: duration_severity)
  end

  def record_state = record.reload.attributes.except("updated_at")

  describe "approval" do
    it "calls correction_approved once with the request, its field, the saved final moment and the reviewer — and writes no attendance itself" do
      handler, calls = recording_handler(approved: applied(worked_minutes: 412, duration_severity: :suspicious))
      expect(Payroll::PunchCorrectionApplier).not_to receive(:call)
      req    = correction
      before = record_state

      with_handler(handler) { expect(approve(req)).to be_success }

      expect(calls.map(&:first)).to eq([ :approved ])
      kwargs = calls.first.last
      expect(kwargs).to eq(request: req, field: :check_in, effective_at: at(9), actor: reviewer)
      expect(kwargs[:request].status).to eq("approved") # called after the request's own write, in the same transaction
      expect(record_state).to eq(before)                 # the handler wrote nothing; Workforce wrote nothing either

      expect(req.reload).to have_attributes(status: "approved", approved_punch_at: at(9), original_check_in_at: at(9, 40),
                                            original_check_out_at: at(15), original_check_in_source: "device",
                                            original_check_out_source: "device")
      window = AuditLog.find_by!(auditable: req, action: "approve").metadata["attendance_window"]
      expect(window).to include("resulting_worked_minutes" => 412, "resulting_duration_severity" => "suspicious",
                                "projected_worked_minutes" => 360) # projected: the pre-write facts
    end

    {
      no_attendance_record:         "No attendance record found for 2026-06-08",
      payroll_locked:               I18n.t("requests.errors.cannot_approve_finalized"),
      check_out_not_after_check_in: I18n.t("requests.errors.check_out_not_after_check_in"),
      check_out_before_check_in:    I18n.t("requests.errors.check_out_before_check_in")
    }.each do |refusal, message|
      it "maps the #{refusal} refusal to its message and rolls the approval back (no snapshot, no audit)" do
        handler, = recording_handler(approved: contract::Approval.new(status: refusal))
        req = correction

        result = with_handler(handler) { approve(req) }

        expect(result.error).to eq(message)
        expect(req.reload).to have_attributes(status: "pending", approved_punch_at: nil, reviewed_by_id: nil,
                                              original_check_in_at: nil)
        expect(audits(req)).to be_empty
      end
    end

    it "an invalid record or any other handler error fails the approval with its message and rolls it back" do
      invalid = AttendanceRecord.new.tap { |r| r.errors.add(:base, "attendance invalid") }
      [ -> { raise ActiveRecord::RecordInvalid.new(invalid) }, -> { raise "boom" } ].zip([ "attendance invalid", "boom" ])
        .each do |raiser, message|
        handler, = recording_handler(approved: raiser)
        req = correction
        expect(with_handler(handler) { approve(req) }.error).to eq(message)
        expect(req.reload.status).to eq("pending")
        expect(audits(req)).to be_empty
      end
    end
  end

  describe "cancellation" do
    let(:approved_request) do
      correction.tap do |req|
        req.update_columns(status: "approved", reviewed_by_id: reviewer.id, reviewed_at: Time.current, approved_punch_at: at(9),
                           original_check_in_at: at(9, 40), original_check_out_at: at(15),
                           original_check_in_source: "device", original_check_out_source: "device")
      end
    end

    it "calls correction_cancelled once with the request, its field, the persisted snapshot and the canceller — and writes no attendance itself" do
      handler, calls = recording_handler(cancelled: :reverted)
      expect(Payroll::PunchCorrectionReverter).not_to receive(:call)
      req    = approved_request
      before = record_state

      with_handler(handler) { expect(cancel(req)).to be_success }

      expect(calls).to eq([ [ :cancelled, { request: req, field: :check_in, snapshot: replaced, actor: reviewer } ] ])
      expect(record_state).to eq(before)
      expect(req.reload).to have_attributes(status: "cancelled", cancelled_by_id: reviewer.id)
      expect(audits(req)).to eq([ "cancel" ])
    end

    it "a check-out correction passes :check_out" do
      handler, calls = recording_handler(cancelled: :reverted)
      req = correction("wrong_check_out_time", "16:00")
      req.update_columns(status: "approved", reviewed_by_id: reviewer.id, original_check_in_at: at(9, 40),
                         original_check_out_at: at(15), original_check_in_source: "device", original_check_out_source: "device")

      with_handler(handler) { cancel(req) }
      expect(calls.first.last[:field]).to eq(:check_out)
    end

    {
      no_attendance_record: I18n.t("requests.errors.no_attendance_record"),
      payroll_locked:       I18n.t("requests.errors.cannot_cancel_finalized")
    }.each do |refusal, message|
      it "maps the #{refusal} refusal to its message and keeps the request approved (no cancel audit)" do
        handler, = recording_handler(cancelled: refusal)
        req = approved_request

        expect(with_handler(handler) { cancel(req) }.error).to eq(message)
        expect(req.reload.status).to eq("approved")
        expect(audits(req)).to be_empty
      end
    end

    it "an invalid record is reported with its messages; any other error propagates; both roll the cancel back" do
      invalid = AttendanceRecord.new.tap { |r| r.errors.add(:base, "attendance invalid") }
      handler, = recording_handler(cancelled: -> { raise ActiveRecord::RecordInvalid.new(invalid) })
      req = approved_request
      expect(with_handler(handler) { cancel(req) }.error).to eq("attendance invalid")
      expect(req.reload.status).to eq("approved")

      handler, = recording_handler(cancelled: -> { raise "boom" })
      expect { with_handler(handler) { cancel(req) } }.to raise_error(RuntimeError, "boom")
      expect(req.reload.status).to eq("approved")
      expect(audits(req)).to be_empty
    end

    it "a pending punch correction is cancelled without calling the contract" do
      handler, calls = recording_handler
      with_handler(handler) { expect(cancel(correction)).to be_success }
      expect(calls).to be_empty
    end
  end
end
