require "rails_helper"

RSpec.describe Attendance::RecordRecomputer do
  # ── Helpers ────────────────────────────────────────────────────────────────

  let(:business) { create(:business, timezone: "UTC") }
  let(:branch)   { create(:branch, business: business) }

  def make_user(code)
    create(:user, business: business, employee_code: code)
  end

  # Creates a record with the stale fields produced by the old CsvImporter
  # (late_minutes: 0, early_leave_minutes: 0, status: "present" even when late/early).
  def stale_imported_record(user:, check_in_hour:, check_out_hour: nil,
                            late_minutes: 0, early_leave_minutes: 0,
                            worked_minutes: nil, status: "present",
                            shift_trait: :fixed_time)
    shift      = create(:shift, shift_trait, business: business)
    assignment = create(:shift_assignment, user: user, branch: branch, shift: shift,
                        effective_from: 1.year.ago.to_date)
    work_date  = Date.current

    check_in  = Time.zone.parse("#{work_date} #{check_in_hour}:00:00")
    check_out = check_out_hour ? Time.zone.parse("#{work_date} #{check_out_hour}:00:00") : nil

    create(:attendance_record,
           user:                user,
           branch:              branch,
           shift_assignment:    assignment,
           work_date:           work_date,
           date:                work_date,
           check_in_at:         check_in,
           check_out_at:        check_out,
           check_in_source:     "import",
           late_minutes:        late_minutes,
           early_leave_minutes: early_leave_minutes,
           worked_minutes:      worked_minutes,
           status:              status)
  end

  # ── recompute! (single-record, in-memory) ──────────────────────────────────

  describe ".recompute!" do
    context "on-time full shift (09:00–17:00)" do
      it "returns false when all fields are already correct" do
        record = stale_imported_record(
          user: make_user("R001"), check_in_hour: 9, check_out_hour: 17,
          late_minutes: 0, early_leave_minutes: 0, worked_minutes: 480, status: "present"
        )
        expect(described_class.recompute!(record)).to be false
      end

      it "does not mutate already-correct fields" do
        record = stale_imported_record(
          user: make_user("R002"), check_in_hour: 9, check_out_hour: 17,
          late_minutes: 0, early_leave_minutes: 0, worked_minutes: 480, status: "present"
        )
        described_class.recompute!(record)
        expect(record.late_minutes).to        eq(0)
        expect(record.early_leave_minutes).to eq(0)
        expect(record.worked_minutes).to      eq(480)
        expect(record.status).to              eq("present")
      end
    end

    context "late check-in (stale: late_minutes = 0, status = 'present')" do
      it "returns true when late_minutes was wrong" do
        record = stale_imported_record(
          user: make_user("R003"), check_in_hour: 10, check_out_hour: 17,
          late_minutes: 0, status: "present"   # stale values from old importer
        )
        expect(described_class.recompute!(record)).to be true
      end

      it "sets late_minutes to the correct value" do
        record = stale_imported_record(
          user: make_user("R004"), check_in_hour: 10, check_out_hour: 17,
          late_minutes: 0, status: "present"
        )
        described_class.recompute!(record)
        expect(record.late_minutes).to eq(60)   # 10:00 vs 09:00 shift start
      end

      it "sets status to 'late'" do
        record = stale_imported_record(
          user: make_user("R005"), check_in_hour: 10, check_out_hour: 17,
          late_minutes: 0, status: "present"
        )
        described_class.recompute!(record)
        expect(record.status).to eq("late")
      end
    end

    context "early checkout (stale: early_leave_minutes = 0, status = 'present')" do
      it "sets early_leave_minutes correctly" do
        record = stale_imported_record(
          user: make_user("R006"), check_in_hour: 9, check_out_hour: 16,
          early_leave_minutes: 0, status: "present"
        )
        described_class.recompute!(record)
        expect(record.early_leave_minutes).to eq(60)   # 16:00 vs 17:00 shift end
      end

      it "sets status to 'early_leave'" do
        record = stale_imported_record(
          user: make_user("R007"), check_in_hour: 9, check_out_hour: 16,
          early_leave_minutes: 0, status: "present"
        )
        described_class.recompute!(record)
        expect(record.status).to eq("early_leave")
      end
    end

    context "late check-in AND early leave" do
      it "sets both penalty fields and the combined late_early_leave status" do
        record = stale_imported_record(
          user: make_user("R008"), check_in_hour: 10, check_out_hour: 16,
          late_minutes: 0, early_leave_minutes: 0, status: "present"
        )
        described_class.recompute!(record)
        expect(record.late_minutes).to        eq(60)
        expect(record.early_leave_minutes).to eq(60)
        expect(record.status).to              eq("late_early_leave")
      end
    end

    context "single punch (no checkout), stale status = 'present'" do
      it "returns true when status was wrong" do
        # Old importer set status = "incomplete" for single punches, so this
        # particular stale combination only occurs if the record was tampered.
        # But late_minutes = 0 for a late single punch is the real regression.
        record = stale_imported_record(
          user: make_user("R009"), check_in_hour: 10, check_out_hour: nil,
          late_minutes: 0, status: "incomplete"
        )
        expect(described_class.recompute!(record)).to be true
      end

      it "sets late_minutes and status for a late single punch" do
        record = stale_imported_record(
          user: make_user("R010"), check_in_hour: 10, check_out_hour: nil,
          late_minutes: 0, status: "incomplete"
        )
        described_class.recompute!(record)
        expect(record.late_minutes).to   eq(60)
        expect(record.status).to         eq("late")
        expect(record.worked_minutes).to be_nil
      end

      it "sets status to 'incomplete' for an on-time single punch" do
        record = stale_imported_record(
          user: make_user("R011"), check_in_hour: 9, check_out_hour: nil,
          late_minutes: 0, status: "incomplete"
        )
        described_class.recompute!(record)
        expect(record.status).to eq("incomplete")
      end
    end

    context "hour-based shift (no fixed start/end times)" do
      it "computes early_leave_minutes as required vs worked shortfall" do
        record = stale_imported_record(
          user: make_user("R012"), check_in_hour: 9, check_out_hour: 16,
          early_leave_minutes: 0, status: "present", shift_trait: :hour_based
        )
        described_class.recompute!(record)
        # required = 8 h (480 min), worked = 7 h (420 min) → shortfall = 60
        expect(record.early_leave_minutes).to eq(60)
        expect(record.status).to              eq("early_leave")
      end
    end

    context "worked_minutes alignment" do
      it "corrects worked_minutes computed with old .round logic" do
        # Edge: old code used .round; canonical uses .to_i.
        # Manufacture a record where the old .round overstated by 1 minute.
        user       = make_user("R013")
        shift      = create(:shift, :fixed_time, business: business)
        assignment = create(:shift_assignment, user: user, branch: branch, shift: shift,
                            effective_from: 1.year.ago.to_date)
        work_date  = Date.current

        # 7h 30m 30s = 27030 s → .round = 451 min, .to_i = 450 min
        check_in  = Time.zone.parse("#{work_date} 09:00:00")
        check_out = check_in + 27030.seconds

        record = create(:attendance_record,
                        user:             user, branch: branch,
                        shift_assignment: assignment,
                        work_date:        work_date, date: work_date,
                        check_in_at:      check_in, check_out_at: check_out,
                        check_in_source:  "import",
                        worked_minutes:   451,   # stale .round value
                        status:           "present")

        described_class.recompute!(record)
        expect(record.worked_minutes).to eq(450)   # corrected to .to_i
      end
    end

    context "record with no shift assignment" do
      it "does not crash and defaults late_minutes to 0 when there is no shift to compare against" do
        user      = create(:user, business: business, employee_code: "R014")
        work_date = Date.current

        # Use AttendanceRecord.create! directly — the FactoryBot factory always
        # auto-creates a shift_assignment via after(:build), so the factory cannot
        # produce a truly shift-assignment-free record.
        record = AttendanceRecord.create!(
          user:                user,
          branch:              branch,
          shift_assignment:    nil,
          work_date:           work_date,
          date:                work_date,
          check_in_at:         Time.zone.parse("#{work_date} 09:30:00"),
          check_out_at:        Time.zone.parse("#{work_date} 17:00:00"),
          check_in_source:     "import",
          late_minutes:        0,
          early_leave_minutes: 0,
          worked_minutes:      450,
          status:              "present"
        )

        # With no shift there is nothing to measure lateness against,
        # so late_minutes and early_leave_minutes both stay 0.
        expect { described_class.recompute!(record) }.not_to raise_error
        expect(record.late_minutes).to        eq(0)
        expect(record.early_leave_minutes).to eq(0)
        expect(record.status).to              eq("present")
      end
    end
  end

  # ── call(scope:) — batch processing ───────────────────────────────────────

  describe ".call(scope:)" do
    it "updates stale records in the scope" do
      user   = make_user("B001")
      record = stale_imported_record(
        user: user, check_in_hour: 10, check_out_hour: 17,
        late_minutes: 0, status: "present"
      )

      result = described_class.call(scope: AttendanceRecord.where(id: record.id))

      expect(result.updated).to eq(1)
      expect(result.skipped).to eq(0)
      expect(result.failed).to  eq(0)
      expect(result.errors).to  be_empty
    end

    it "persists the corrected values to the database" do
      user   = make_user("B002")
      record = stale_imported_record(
        user: user, check_in_hour: 10, check_out_hour: 17,
        late_minutes: 0, status: "present"
      )

      described_class.call(scope: AttendanceRecord.where(id: record.id))

      record.reload
      expect(record.late_minutes).to eq(60)
      expect(record.status).to       eq("late")
    end

    it "skips records that are already correct" do
      user   = make_user("B003")
      record = stale_imported_record(
        user: user, check_in_hour: 9, check_out_hour: 17,
        late_minutes: 0, early_leave_minutes: 0, worked_minutes: 480, status: "present"
      )

      result = described_class.call(scope: AttendanceRecord.where(id: record.id))

      expect(result.updated).to eq(0)
      expect(result.skipped).to eq(1)
    end

    it "processes multiple records and returns accurate counts" do
      user1 = make_user("B004")
      user2 = make_user("B005")
      user3 = make_user("B006")

      stale1 = stale_imported_record(user: user1, check_in_hour: 10, check_out_hour: 17,
                                     late_minutes: 0, status: "present")
      stale2 = stale_imported_record(user: user2, check_in_hour: 9,  check_out_hour: 16,
                                     early_leave_minutes: 0, status: "present")
      ok     = stale_imported_record(user: user3, check_in_hour: 9,  check_out_hour: 17,
                                     late_minutes: 0, early_leave_minutes: 0,
                                     worked_minutes: 480, status: "present")

      ids    = [stale1.id, stale2.id, ok.id]
      result = described_class.call(scope: AttendanceRecord.where(id: ids))

      expect(result.updated).to eq(2)
      expect(result.skipped).to eq(1)
    end

    it "collects affected_periods for regeneration downstream" do
      user   = make_user("B007")
      record = stale_imported_record(
        user: user, check_in_hour: 10, check_out_hour: 17,
        late_minutes: 0, status: "present"
      )

      result = described_class.call(scope: AttendanceRecord.where(id: record.id))

      expected_period = [user.business_id, Date.current.year, Date.current.month]
      expect(result.affected_periods).to include(expected_period)
    end

    it "does not include periods for skipped (unchanged) records in affected_periods" do
      user   = make_user("B008")
      record = stale_imported_record(
        user: user, check_in_hour: 9, check_out_hour: 17,
        late_minutes: 0, early_leave_minutes: 0, worked_minutes: 480, status: "present"
      )

      result = described_class.call(scope: AttendanceRecord.where(id: record.id))

      expect(result.affected_periods).to be_empty
    end

    it "handles individual record errors gracefully without aborting the batch" do
      user1  = make_user("B009")
      user2  = make_user("B010")
      stale1 = stale_imported_record(user: user1, check_in_hour: 10, check_out_hour: 17,
                                     late_minutes: 0, status: "present")
      stale2 = stale_imported_record(user: user2, check_in_hour: 10, check_out_hour: 17,
                                     late_minutes: 0, status: "present")

      allow(stale1).to receive(:save!).and_raise(ActiveRecord::RecordInvalid)
      # Must intercept at the record level — stub the class to return the problematic record
      allow(AttendanceRecord).to receive(:find).and_call_original
      allow_any_instance_of(AttendanceRecord).to receive(:save!).and_call_original
      allow_any_instance_of(AttendanceRecord).to receive(:save!)
        .with(no_args)
        .and_call_original

      # Simulate one record failing: mock the instance matching stale1
      # Use a deterministic approach — process two records, verify one still completes
      saved_ids = []
      allow_any_instance_of(AttendanceRecord).to receive(:save!) do |rec|
        if rec.id == stale1.id
          raise ActiveRecord::RecordInvalid.new(rec)
        end
        rec.send(:create_or_update)
        saved_ids << rec.id
      end

      result = described_class.call(scope: AttendanceRecord.where(id: [stale1.id, stale2.id]))

      expect(result.failed).to eq(1)
      expect(result.errors.first[:record_id]).to eq(stale1.id)
      expect(saved_ids).to include(stale2.id)
    end
  end
end
