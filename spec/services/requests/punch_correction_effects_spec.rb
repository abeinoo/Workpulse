require "rails_helper"

# Pilot 10 — Punch Correction, M2: the Workforce contract
# Requests::PunchCorrectionEffects and its Attendance & Payroll implementation
# Attendance::PunchCorrectionEffects. Since M3 Requests::PunchCorrectionAssessment
# reads its attendance facts through correction_facts
# (punch_correction_assessment_routing_spec.rb); correction_facts must equal the
# direct reads the assessment made before M3. correction_approved /
# correction_cancelled are implemented in M4-2 (with the actor argument); the
# approve / cancel behaviour stays pinned by the M1 and M4-1 characterization
# (spec/characterization/workforce/punch_correction_effects_spec.rb,
# punch_correction_m4_baseline_spec.rb).
RSpec.describe Requests::PunchCorrectionEffects do
  around { |ex| travel_to(Time.zone.local(2026, 7, 15, 12, 0, 0)) { ex.run } }

  let(:business) { create(:business) }
  let(:tz)       { ActiveSupport::TimeZone[business.timezone] }
  let(:branch)   { create(:branch, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:shift) do
    create(:shift, :fixed_time, business: business, start_time: Time.zone.parse("09:00"), end_time: Time.zone.parse("17:00"))
  end
  let!(:assignment) do
    create(:shift_assignment, user: employee, branch: branch, shift: shift, effective_from: Date.new(2026, 1, 1))
  end
  let(:day) { Date.new(2026, 6, 8) }
  let(:actor) { create(:user, business: business) }

  def at(hour, minute = 0, date: day) = tz.local(date.year, date.month, date.day, hour, minute)

  def attendance(check_in: at(9, 40), check_out: at(15, 0))
    @attendance ||= create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment,
                                               date: day, work_date: day, check_in_at: check_in, check_out_at: check_out,
                                               check_in_source: "device", check_out_source: "device",
                                               worked_minutes: check_out ? ((check_out - check_in) / 60).to_i : nil)
  end

  def correction(type, time, date: day)
    build(:employee_request, :punch_correction, :pending, user: employee, requested_for_date: day, correction_type: type,
                                                          proposed_time: time, proposed_date: date)
      .tap { |req| req.save!(validate: false) }
  end

  def snapshot(**attrs) = described_class::Snapshot.new(**attrs)

  # Swaps the registered handler for one example and always restores it.
  def with_handler(handler)
    original = described_class.instance_variable_get(:@handler)
    described_class.instance_variable_set(:@handler, handler)
    yield
  ensure
    described_class.instance_variable_set(:@handler, original)
  end

  def handler_returning(facts: nil, approval: nil, cancelled: nil)
    Module.new do
      define_singleton_method(:correction_facts) { |**| facts }
      define_singleton_method(:correction_approved) { |**| approval }
      define_singleton_method(:correction_cancelled) { |**| cancelled }
    end
  end

  describe "registration" do
    it "has the Attendance & Payroll implementation registered at boot" do
      expect(described_class.handler).to equal(Attendance::PunchCorrectionEffects)
    end

    it "rejects a handler that does not implement every operation, keeping the current one" do
      incomplete = Module.new { def self.correction_facts(**) = nil }

      expect { described_class.register(incomplete) }
        .to raise_error(ArgumentError, /correction_approved, correction_cancelled/)
      expect(described_class.handler).to equal(Attendance::PunchCorrectionEffects)
    end

    it "raises NotRegistered (a StandardError) instead of silently skipping when no handler is registered" do
      req = correction("missing_check_in", "09:00")
      expect(described_class::NotRegistered.ancestors).to include(StandardError)
      with_handler(nil) do
        expect { described_class.correction_facts(request: req, field: :check_in, effective_at: at(9)) }
          .to raise_error(described_class::NotRegistered)
        expect { described_class.correction_approved(request: req, field: :check_in, effective_at: at(9), actor: actor) }
          .to raise_error(described_class::NotRegistered)
        expect { described_class.correction_cancelled(request: req, field: :check_in, snapshot: snapshot, actor: actor) }
          .to raise_error(described_class::NotRegistered)
      end
    end
  end

  describe "argument and result validation" do
    let(:req) { correction("missing_check_in", "09:00") }
    let(:facts) { described_class::Facts.new(record_found: true) }

    it "refuses an unknown field before calling the handler" do
      with_handler(handler_returning(facts: facts)) do
        expect { described_class.correction_facts(request: req, field: :lunch, effective_at: at(9)) }
          .to raise_error(ArgumentError, /field must be one of/)
        expect { described_class.correction_approved(request: req, field: "check_in", effective_at: at(9), actor: actor) }
          .to raise_error(ArgumentError, /field must be one of/)
      end
    end

    it "requires a User actor for approval and cancellation before calling the handler (M4-2)" do
      handler = handler_returning(approval: described_class::Approval.new(status: :payroll_locked), cancelled: :reverted)
      allow(handler).to receive(:correction_approved).and_call_original
      allow(handler).to receive(:correction_cancelled).and_call_original

      with_handler(handler) do
        [ nil, actor.id, "reviewer" ].each do |bad|
          expect { described_class.correction_approved(request: req, field: :check_in, effective_at: at(9), actor: bad) }
            .to raise_error(ArgumentError, /actor must be a User/)
          expect { described_class.correction_cancelled(request: req, field: :check_in, snapshot: snapshot, actor: bad) }
            .to raise_error(ArgumentError, /actor must be a User/)
        end
        expect { described_class.correction_approved(request: req, field: :check_in, effective_at: at(9)) }
          .to raise_error(ArgumentError, /missing keyword: :actor/)

        described_class.correction_approved(request: req, field: :check_in, effective_at: at(9), actor: actor)
        described_class.correction_cancelled(request: req, field: :check_in, snapshot: snapshot, actor: actor)
      end

      expect(handler).to have_received(:correction_approved).once
        .with(request: req, field: :check_in, effective_at: at(9), actor: actor)
      expect(handler).to have_received(:correction_cancelled).once
        .with(request: req, field: :check_in, snapshot: snapshot, actor: actor)
    end

    it "requires a Snapshot for cancellation and accepts nil or a Snapshot as the facts baseline" do
      with_handler(handler_returning(facts: facts, cancelled: :reverted)) do
        expect { described_class.correction_cancelled(request: req, field: :check_in, snapshot: nil, actor: actor) }
          .to raise_error(ArgumentError, /expected a .*Snapshot/)
        expect { described_class.correction_facts(request: req, field: :check_in, effective_at: at(9), baseline: {}) }
          .to raise_error(ArgumentError, /expected a .*Snapshot/)
        expect(described_class.correction_facts(request: req, field: :check_in, effective_at: at(9))).to equal(facts)
        expect(described_class.correction_facts(request: req, field: :check_in, effective_at: at(9), baseline: snapshot))
          .to equal(facts)
      end
    end

    it "refuses a facts result that is not a Facts" do
      with_handler(handler_returning(facts: { record_found: true })) do
        expect { described_class.correction_facts(request: req, field: :check_in, effective_at: at(9)) }
          .to raise_error(ArgumentError, /expected .*Facts/)
      end
    end

    it "passes through an applied Approval with a Snapshot, and each refusal" do
      applied = described_class::Approval.new(status: :applied, snapshot: snapshot(check_in_at: at(9, 40)),
                                              worked_minutes: 360, duration_severity: nil)
      with_handler(handler_returning(approval: applied)) do
        result = described_class.correction_approved(request: req, field: :check_in, effective_at: at(9), actor: actor)
        expect(result).to equal(applied)
        expect(result).to be_applied
      end

      described_class::REFUSALS.each do |reason|
        refusal = described_class::Approval.new(status: reason)
        with_handler(handler_returning(approval: refusal)) do
          expect(described_class.correction_approved(request: req, field: :check_in, effective_at: at(9), actor: actor)).to be_refused
        end
      end
    end

    it "refuses a malformed Approval: not an Approval, applied without a Snapshot, or an unknown status" do
      [ :applied, described_class::Approval.new(status: :applied),
        described_class::Approval.new(status: :weekend, snapshot: snapshot) ].each do |bad|
        with_handler(handler_returning(approval: bad)) do
          expect { described_class.correction_approved(request: req, field: :check_in, effective_at: at(9), actor: actor) }
            .to raise_error(ArgumentError)
        end
      end
    end

    it "passes through each cancel result and refuses anything else" do
      described_class::CANCEL_RESULTS.each do |result|
        with_handler(handler_returning(cancelled: result)) do
          expect(described_class.correction_cancelled(request: req, field: :check_in, snapshot: snapshot, actor: actor)).to eq(result)
        end
      end

      [ nil, true, :refused, "reverted" ].each do |bad|
        with_handler(handler_returning(cancelled: bad)) do
          expect { described_class.correction_cancelled(request: req, field: :check_in, snapshot: snapshot, actor: actor) }
            .to raise_error(ArgumentError, /expected one of/)
        end
      end
    end

    it "lets an unexpected handler error propagate to the caller" do
      failing = handler_returning
      failing.define_singleton_method(:correction_cancelled) { |**| raise ActiveRecord::RecordInvalid }
      with_handler(failing) do
        expect { described_class.correction_cancelled(request: req, field: :check_in, snapshot: snapshot, actor: actor) }
          .to raise_error(ActiveRecord::RecordInvalid)
      end
    end
  end

  # Since M3 the assessment itself reads these facts through the contract, so
  # parity is measured against the direct Attendance & Payroll reads it made
  # before (the oracle below), not against the assessment.
  describe "Attendance::PunchCorrectionEffects.correction_facts — parity with the pre-M3 assessment reads" do
    def oracle_for(req, effective_at, baseline)
      window = Attendance::PunchWindow.for(user: req.user, work_date: req.requested_for_date)
      record = AttendanceRecord.find_by(user: req.user, work_date: req.requested_for_date)
      check_in_at  = baseline ? baseline.check_in_at  : record&.check_in_at
      check_out_at = baseline ? baseline.check_out_at : record&.check_out_at
      minutes = nil
      if record && effective_at
        copy = record.dup
        copy.check_in_at  = req.correction_field == :check_in  ? effective_at : check_in_at
        copy.check_out_at = req.correction_field == :check_out ? effective_at : check_out_at
        Attendance::RecordRecomputer.recompute!(copy)
        minutes = copy.worked_minutes
      end
      { inside_window: window.cover?(effective_at), check_in_at: check_in_at, check_out_at: check_out_at,
        shift_name: window.shift&.name, shift_starts_at: window.shift_starts_at, shift_ends_at: window.shift_ends_at,
        projected_worked_minutes: minutes,
        duration_severity: Attendance::DurationCheck.severity(minutes, business: req.user.business) }
    end

    def facts_for(req, baseline: nil)
      effective_at = Requests::PunchCorrectionApplier.effective_punch_at(request: req)
      facts = described_class.correction_facts(request: req, field: req.correction_field,
                                               effective_at: effective_at, baseline: baseline)
      [ facts, oracle_for(req, effective_at, baseline) ]
    end

    def expect_parity(facts, expected)
      expect(facts).to be_a(described_class::Facts)
      expect(facts.to_h.except(:record_found, :shift_required_hours)).to eq(expected)
    end

    it "a check-in correction inside the window" do
      attendance
      facts, assessment = facts_for(correction("wrong_check_in_time", "09:00"))

      expect_parity(facts, assessment)
      expect(facts).to have_attributes(record_found?: true, inside_window?: true, projected_worked_minutes: 360,
                                       shift_starts_at: at(9), shift_ends_at: at(17), duration_severity: nil)
    end

    it "a check-out correction on another date, outside the window" do
      attendance
      facts, assessment = facts_for(correction("wrong_check_out_time", "15:00", date: day + 3))

      expect_parity(facts, assessment)
      expect(facts.inside_window?).to be(false)
    end

    it "an overnight check-out producing an abnormal duration" do
      attendance
      facts, assessment = facts_for(correction("wrong_check_out_time", "03:00", date: day + 1))

      expect_parity(facts, assessment)
      expect(facts.duration_severity).to be_present
    end

    it "a missing check-out: projected minutes once the punch is supplied, none when the other punch is missing" do
      attendance(check_out: nil)
      facts, assessment = facts_for(correction("missing_check_out", "17:00"))
      expect_parity(facts, assessment)
      expect(facts.projected_worked_minutes).to eq(440)

      facts, assessment = facts_for(correction("wrong_check_in_time", "09:00"))
      expect_parity(facts, assessment)
      expect(facts.projected_worked_minutes).to be_nil
    end

    it "no attendance record: record_found false, the window still judged, nothing projected" do
      facts, assessment = facts_for(correction("missing_check_in", "09:00"))

      expect_parity(facts, assessment)
      expect(facts).to have_attributes(record_found?: false, check_in_at: nil, check_out_at: nil,
                                       projected_worked_minutes: nil)
    end

    it "an applied correction is judged against the baseline Snapshot, as the assessment uses the request's snapshot" do
      attendance(check_in: at(9, 0)) # already corrected to 09:00
      req = correction("wrong_check_in_time", "09:00")
      req.update_columns(status: "approved", approved_punch_at: at(9, 0), original_check_in_at: at(9, 40),
                         original_check_out_at: at(15, 0), original_check_in_source: "device",
                         original_check_out_source: "device")
      baseline = snapshot(check_in_at: req.original_check_in_at, check_out_at: req.original_check_out_at,
                          check_in_source: "device", check_out_source: "device")

      facts, assessment = facts_for(req, baseline: baseline)

      expect_parity(facts, assessment)
      expect(facts.check_in_at).to eq(at(9, 40))
    end

    it "reads only: the attendance record and the request are unchanged" do
      record = attendance
      req = correction("wrong_check_in_time", "09:00")
      before_record  = record.reload.attributes
      before_request = req.reload.attributes

      facts_for(req)

      expect(record.reload.attributes).to eq(before_record)
      expect(req.reload.attributes).to eq(before_request)
    end
  end

  # Implemented in M4-2. The end-to-end behaviour (through Requests::Approver /
  # Requests::Canceller) stays pinned by the M1 and M4-1 characterization; these
  # pin the implementation's own contract: plain results, refusals before any
  # write, and the request never written.
  describe "Attendance::PunchCorrectionEffects approval and cancellation (M4-2)" do
    def approved(req, effective_at)
      described_class.correction_approved(request: req, field: req.correction_field, effective_at: effective_at, actor: actor)
    end

    it "approval applies the punch and returns the replaced punches and the resulting values, never writing the request" do
      record = attendance
      req    = correction("wrong_check_in_time", "09:00")
      before = req.attributes

      approval = approved(req, at(9))

      expect(approval).to be_applied
      expect(approval.snapshot).to eq(snapshot(check_in_at: at(9, 40), check_out_at: at(15), check_in_source: "device",
                                               check_out_source: "device"))
      expect(approval.worked_minutes).to eq(360)
      expect(approval.duration_severity).to be_nil
      expect(record.reload).to have_attributes(check_in_at: at(9), check_in_source: "admin_manual", worked_minutes: 360)
      expect(req.reload.attributes).to eq(before)
      [ approval, approval.snapshot ].each { |value| expect(value).to be_a(Struct) }
    end

    it "approval refusals are decided before anything is written, in order" do
      req = correction("wrong_check_in_time", "09:00")
      expect(approved(req, at(9)).status).to eq(:no_attendance_record)

      record = attendance
      create(:payroll_period, business: business, period_year: 2026, period_month: 6, working_days: 22, status: "paid")
      expect(approved(req, at(9)).status).to eq(:payroll_locked)
      PayrollPeriod.update_all(status: "under_review")

      expect(approved(correction("wrong_check_out_time", "09:40"), at(9, 40)).status).to eq(:check_out_not_after_check_in)
      expect(approved(req, at(16)).status).to eq(:check_out_before_check_in)
      expect(record.reload).to have_attributes(check_in_at: at(9, 40), check_out_at: at(15), check_in_source: "device")
    end

    it "cancellation restores the field from the snapshot, refuses in order, and never writes the request" do
      req = correction("wrong_check_in_time", "09:00")
      original = snapshot(check_in_at: at(9, 40), check_out_at: at(15), check_in_source: "device", check_out_source: "device")
      cancel = -> { described_class.correction_cancelled(request: req, field: :check_in, snapshot: original, actor: actor) }

      expect(cancel.call).to eq(:no_attendance_record)
      record = attendance
      record.update!(check_in_at: at(9), check_in_source: "admin_manual")
      period = create(:payroll_period, business: business, period_year: 2026, period_month: 6, working_days: 22,
                                       status: "finalized")
      expect(cancel.call).to eq(:payroll_locked)
      expect(record.reload.check_in_at).to eq(at(9))

      period.update_column(:status, "under_review")
      before = req.reload.attributes
      expect(cancel.call).to eq(:reverted)
      expect(record.reload).to have_attributes(check_in_at: at(9, 40), check_in_source: "device")
      expect(req.reload.attributes).to eq(before)
    end
  end
end
