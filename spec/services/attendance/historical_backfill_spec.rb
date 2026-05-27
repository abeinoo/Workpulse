require "rails_helper"

RSpec.describe Attendance::HistoricalBackfill do
  # ── Helpers ────────────────────────────────────────────────────────────────

  let(:business) { create(:business, timezone: "UTC") }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }

  def make_employee(code, biz: business, b: branch)
    user   = create(:user, business: biz, employee_code: code)
    shift  = create(:shift, :fixed_time, business: biz)  # 09:00–17:00
    assign = create(:shift_assignment, user: user, branch: b, shift: shift,
                    effective_from: 1.year.ago.to_date)
    user
  end

  # Builds an attendance_record as the old CsvImporter would have left it:
  # late_minutes = 0, early_leave_minutes = 0, status depends on checkout presence.
  def old_import_record(user:, work_date:, check_in_hour:, check_out_hour: nil)
    check_in  = Time.zone.parse("#{work_date} #{"%02d" % check_in_hour}:00:00")
    check_out = check_out_hour ?
                  Time.zone.parse("#{work_date} #{"%02d" % check_out_hour}:00:00") : nil

    create(:attendance_record,
           user:                user,
           branch:              user.shift_assignments.first.branch,
           shift_assignment:    user.shift_assignments.first,
           work_date:           work_date,
           date:                work_date,
           check_in_at:         check_in,
           check_out_at:        check_out,
           check_in_source:     "import",
           late_minutes:        0,
           early_leave_minutes: 0,
           worked_minutes:      check_out_hour ? (check_out_hour - check_in_hour) * 60 : nil,
           status:              check_out_hour ? "present" : "incomplete")
  end

  def run_backfill(**opts)
    described_class.call(performed_by: actor, **opts)
  end

  # ── Scope: which records are targeted ─────────────────────────────────────

  describe "scope filtering" do
    it "only processes records with check_in_source = 'import'" do
      emp = make_employee("S001")
      wd  = Date.current

      _biometric = create(:attendance_record,
                          user: emp, branch: branch,
                          shift_assignment: emp.shift_assignments.first,
                          work_date: wd + 1, date: wd + 1,
                          check_in_at: Time.zone.parse("#{wd + 1} 10:00:00"),
                          check_in_source: "biometric_device",
                          late_minutes: 0, status: "late")

      import_rec = old_import_record(user: emp, work_date: wd, check_in_hour: 10, check_out_hour: 17)

      run_backfill(business: business)

      import_rec.reload
      expect(import_rec.late_minutes).to eq(60)  # fixed

      # biometric record must be completely untouched
      _biometric.reload
      expect(_biometric.late_minutes).to eq(0)   # not touched
    end

    it "limits to the given business when business: is supplied" do
      other_biz    = create(:business, timezone: "UTC")
      other_branch = create(:branch, business: other_biz)
      other_emp    = make_employee("S002", biz: other_biz, b: other_branch)
      wd           = Date.current

      _other_rec = old_import_record(user: other_emp, work_date: wd,
                                     check_in_hour: 10, check_out_hour: 17)

      run_backfill(business: business)   # scoped to @business only

      _other_rec.reload
      expect(_other_rec.late_minutes).to eq(0)  # should not have been touched
    end

    it "limits to the from/to date window when supplied" do
      emp = make_employee("S003")

      inside  = old_import_record(user: emp, work_date: Date.new(2026, 5, 10),
                                  check_in_hour: 10, check_out_hour: 17)
      outside = old_import_record(user: emp, work_date: Date.new(2026, 4, 5),
                                  check_in_hour: 10, check_out_hour: 17)

      run_backfill(business: business,
                   from: Date.new(2026, 5, 1),
                   to:   Date.new(2026, 5, 31))

      inside.reload
      outside.reload
      expect(inside.late_minutes).to  eq(60)  # inside window → fixed
      expect(outside.late_minutes).to eq(0)   # outside window → untouched
    end
  end

  # ── Recomputation correctness ──────────────────────────────────────────────

  describe "attendance field recomputation" do
    it "sets the correct late_minutes and status for a late check-in" do
      emp    = make_employee("C001")
      record = old_import_record(user: emp, work_date: Date.current,
                                 check_in_hour: 10, check_out_hour: 17)

      run_backfill(business: business)

      record.reload
      expect(record.late_minutes).to eq(60)   # 10:00 vs 09:00 shift start
      expect(record.status).to       eq("late")
    end

    it "sets the correct early_leave_minutes and status for an early checkout" do
      emp    = make_employee("C002")
      record = old_import_record(user: emp, work_date: Date.current,
                                 check_in_hour: 9, check_out_hour: 16)

      run_backfill(business: business)

      record.reload
      expect(record.early_leave_minutes).to eq(60)   # 16:00 vs 17:00 shift end
      expect(record.status).to              eq("early_leave")
    end

    it "sets 'late' status for a late single-punch record (stale status was 'incomplete')" do
      emp    = make_employee("C003")
      record = old_import_record(user: emp, work_date: Date.current,
                                 check_in_hour: 10, check_out_hour: nil)

      run_backfill(business: business)

      record.reload
      expect(record.late_minutes).to eq(60)
      expect(record.status).to       eq("late")
    end

    it "leaves already-correct records unchanged" do
      emp    = make_employee("C004")
      wd     = Date.current
      record = create(:attendance_record,
                      user: emp, branch: branch,
                      shift_assignment: emp.shift_assignments.first,
                      work_date: wd, date: wd,
                      check_in_at:         Time.zone.parse("#{wd} 09:00:00"),
                      check_out_at:        Time.zone.parse("#{wd} 17:00:00"),
                      check_in_source:     "import",
                      late_minutes:        0,
                      early_leave_minutes: 0,
                      worked_minutes:      480,
                      status:              "present")

      expect { run_backfill(business: business) }.not_to change { record.reload.updated_at }
    end
  end

  # ── Return value ──────────────────────────────────────────────────────────

  describe "result counts" do
    it "reports the number of records updated and skipped" do
      emp1 = make_employee("RES001")
      emp2 = make_employee("RES002")
      wd   = Date.current

      old_import_record(user: emp1, work_date: wd,
                        check_in_hour: 10, check_out_hour: 17)          # stale → updated
      create(:attendance_record,
             user: emp2, branch: branch,
             shift_assignment: emp2.shift_assignments.first,
             work_date: wd + 1, date: wd + 1,
             check_in_at:     Time.zone.parse("#{wd + 1} 09:00:00"),
             check_out_at:    Time.zone.parse("#{wd + 1} 17:00:00"),
             check_in_source: "import",
             late_minutes:    0, early_leave_minutes: 0,
             worked_minutes:  480, status: "present")                    # correct → skipped

      result = run_backfill(business: business)

      expect(result.records_updated).to eq(1)
      expect(result.records_skipped).to eq(1)
      expect(result.records_failed).to  eq(0)
    end

    it "returns a success? result when no records fail" do
      make_employee("RES003")
      result = run_backfill(business: business)
      expect(result.success?).to be true
    end

    it "includes a human-readable summary" do
      result = run_backfill(business: business)
      expect(result.summary).to match(/Records:.*updated.*skipped.*failed/)
      expect(result.summary).to match(/Payrolls:.*regenerated.*skipped/)
    end
  end

  # ── Payroll regeneration ──────────────────────────────────────────────────

  describe "payroll regeneration" do
    it "regenerates a draft payroll period for the month of a fixed stale record" do
      emp    = make_employee("P001")
      wd     = Date.current

      old_import_record(user: emp, work_date: wd, check_in_hour: 10, check_out_hour: 17)

      create(:payroll_period, business: business,
             period_year: wd.year, period_month: wd.month, status: :draft)

      expect(Payroll::PeriodGenerator).to receive(:call).with(
        business:     business,
        year:         wd.year,
        month:        wd.month,
        generated_by: actor
      )

      run_backfill(business: business)
    end

    it "does not regenerate when no draft payroll period exists for that month" do
      emp = make_employee("P002")
      old_import_record(user: emp, work_date: Date.current,
                        check_in_hour: 10, check_out_hour: 17)

      expect(Payroll::PeriodGenerator).not_to receive(:call)
      result = run_backfill(business: business)

      expect(result.payrolls_regenerated).to eq(0)
      expect(result.payrolls_skipped).to     eq(1)
    end

    it "does not regenerate a finalized payroll period" do
      emp = make_employee("P003")
      wd  = Date.current

      old_import_record(user: emp, work_date: wd,
                        check_in_hour: 10, check_out_hour: 17)

      create(:payroll_period, business: business,
             period_year: wd.year, period_month: wd.month, status: :finalized)

      expect(Payroll::PeriodGenerator).not_to receive(:call)
      run_backfill(business: business)
    end

    it "does not regenerate a paid payroll period" do
      emp = make_employee("P004")
      wd  = Date.current

      old_import_record(user: emp, work_date: wd,
                        check_in_hour: 10, check_out_hour: 17)

      create(:payroll_period, business: business,
             period_year: wd.year, period_month: wd.month, status: :paid)

      expect(Payroll::PeriodGenerator).not_to receive(:call)
      run_backfill(business: business)
    end

    it "does not regenerate payroll when no records were actually changed" do
      emp = make_employee("P005")
      wd  = Date.current

      create(:attendance_record,
             user: emp, branch: branch,
             shift_assignment: emp.shift_assignments.first,
             work_date: wd, date: wd,
             check_in_at:     Time.zone.parse("#{wd} 09:00:00"),
             check_out_at:    Time.zone.parse("#{wd} 17:00:00"),
             check_in_source: "import",
             late_minutes: 0, early_leave_minutes: 0,
             worked_minutes: 480, status: "present")  # already correct

      create(:payroll_period, business: business,
             period_year: wd.year, period_month: wd.month, status: :draft)

      expect(Payroll::PeriodGenerator).not_to receive(:call)
      run_backfill(business: business)
    end

    it "regenerates once per month even when multiple records in the same month changed" do
      emp1 = make_employee("P006")
      emp2 = make_employee("P007")
      wd   = Date.current

      old_import_record(user: emp1, work_date: wd, check_in_hour: 10, check_out_hour: 17)
      old_import_record(user: emp2, work_date: wd + 1, check_in_hour: 10, check_out_hour: 17)

      create(:payroll_period, business: business,
             period_year: wd.year, period_month: wd.month, status: :draft)

      expect(Payroll::PeriodGenerator).to receive(:call).once
      run_backfill(business: business)
    end

    it "regenerates each distinct month separately" do
      emp  = make_employee("P008")
      apr  = Date.new(2026, 4, 28)
      may  = Date.new(2026, 5,  2)

      old_import_record(user: emp, work_date: apr, check_in_hour: 10, check_out_hour: 17)
      old_import_record(user: emp, work_date: may, check_in_hour: 10, check_out_hour: 17)

      create(:payroll_period, business: business,
             period_year: 2026, period_month: 4, status: :draft)
      create(:payroll_period, business: business,
             period_year: 2026, period_month: 5, status: :draft)

      expect(Payroll::PeriodGenerator).to receive(:call).twice
      run_backfill(business: business)
    end

    it "counts regenerated and skipped payrolls in the result" do
      emp = make_employee("P009")
      wd  = Date.current

      old_import_record(user: emp, work_date: wd, check_in_hour: 10, check_out_hour: 17)

      # draft period exists → will be regenerated
      create(:payroll_period, business: business,
             period_year: wd.year, period_month: wd.month, status: :draft)

      allow(Payroll::PeriodGenerator).to receive(:call)   # prevent real regeneration
      result = run_backfill(business: business)

      expect(result.payrolls_regenerated).to eq(1)
      expect(result.payrolls_skipped).to     eq(0)
    end
  end

  # ── Idempotency ───────────────────────────────────────────────────────────

  describe "idempotency" do
    it "produces the same attendance state when run twice" do
      emp    = make_employee("I001")
      wd     = Date.current
      record = old_import_record(user: emp, work_date: wd,
                                 check_in_hour: 10, check_out_hour: 17)

      run_backfill(business: business)
      first_late = record.reload.late_minutes

      run_backfill(business: business)
      expect(record.reload.late_minutes).to eq(first_late)
    end

    it "skips all records (zero updates) on the second run" do
      emp = make_employee("I002")
      old_import_record(user: emp, work_date: Date.current,
                        check_in_hour: 10, check_out_hour: 17)

      run_backfill(business: business)
      second_result = run_backfill(business: business)

      expect(second_result.records_updated).to eq(0)
      expect(second_result.records_skipped).to be >= 1
    end
  end
end
