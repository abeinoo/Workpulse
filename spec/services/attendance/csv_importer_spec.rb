require "rails_helper"

RSpec.describe Attendance::CsvImporter do
  let(:business) { create(:business, timezone: "UTC") }
  let(:branch)   { create(:branch, business: business) }

  # Build a user with a known employee_code and an active shift assignment
  def make_employee(code:)
    user  = create(:user, business: business, employee_code: code)
    shift = create(:shift, :fixed_time, business: business)
    create(:shift_assignment, user: user, branch: branch, shift: shift,
           effective_from: 1.year.ago.to_date)
    user
  end

  # ── CSV helpers ────────────────────────────────────────────────────────────

  def build_csv(*rows)
    header = "employee_code,check_in_at,check_out_at\n"
    body   = rows.map { |r| "#{r[:code]},#{r[:check_in]},#{r[:check_out]}" }.join("\n")
    header + body
  end

  def run_import(csv_string, user: nil)
    result = described_class.parse(csv_string, business: business)
    raise "Parse failed: #{result.header_error}" unless result.headers_valid?

    log = AttendanceImportLog.create!(
      business:     business,
      imported_by:  user || create(:user, business: business),
      filename:     "test.csv",
      status:       "pending",
      total_rows:   result.total_rows,
      imported_rows: 0,
      failed_rows_count: result.rows.count { |r| !r["valid"] },
      metadata:     { "preview" => result.rows }
    )

    described_class.execute(log)
    log.reload
  end

  # ── Scenario 1: mobile check-in already exists, CSV arrives later ──────────

  describe "mobile check-in + CSV merge" do
    it "preserves the earlier mobile check-in when CSV check-in is later" do
      employee = make_employee(code: "EMP001")
      work_day = Date.current

      # Simulate mobile check-in at 08:00
      mobile_checkin = Time.zone.parse("#{work_day} 08:00:00")
      record = create(
        :attendance_record,
        user:        employee,
        branch:      branch,
        work_date:   work_day,
        date:        work_day,
        check_in_at: mobile_checkin,
        status:      "incomplete",
        shift_assignment: employee.shift_assignments.first
      )

      # CSV arrives with a later check-in (09:30) for the same day
      csv = build_csv({ code: "EMP001", check_in: "#{work_day} 09:30", check_out: "#{work_day} 17:00" })
      run_import(csv)

      record.reload
      expect(record.check_in_at).to eq(mobile_checkin)
    end

    it "updates check_out_at from CSV when mobile had no checkout" do
      employee = make_employee(code: "EMP002")
      work_day = Date.current

      create(
        :attendance_record,
        user:        employee,
        branch:      branch,
        work_date:   work_day,
        date:        work_day,
        check_in_at: Time.zone.parse("#{work_day} 08:00:00"),
        check_out_at: nil,
        status:       "incomplete",
        shift_assignment: employee.shift_assignments.first
      )

      csv = build_csv({ code: "EMP002", check_in: "#{work_day} 09:30", check_out: "#{work_day} 17:00" })
      run_import(csv)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.check_out_at).to eq(Time.zone.parse("#{work_day} 17:00:00"))
    end

    it "does not create a duplicate row" do
      employee = make_employee(code: "EMP003")
      work_day = Date.current

      create(
        :attendance_record,
        user:        employee,
        branch:      branch,
        work_date:   work_day,
        date:        work_day,
        check_in_at: Time.zone.parse("#{work_day} 08:00:00"),
        shift_assignment: employee.shift_assignments.first
      )

      csv = build_csv({ code: "EMP003", check_in: "#{work_day} 09:00", check_out: "" })
      expect {
        run_import(csv)
      }.not_to change(AttendanceRecord, :count)
    end
  end

  # ── Scenario 2: biometric check-in exists, CSV arrives later ──────────────

  describe "biometric check-in + CSV merge" do
    it "preserves the earlier biometric check-in when CSV check-in is later" do
      employee = make_employee(code: "BIO001")
      work_day = Date.current

      biometric_checkin = Time.zone.parse("#{work_day} 07:45:00")
      create(
        :attendance_record,
        user:        employee,
        branch:      branch,
        work_date:   work_day,
        date:        work_day,
        check_in_at: biometric_checkin,
        shift_assignment: employee.shift_assignments.first
      )

      csv = build_csv({ code: "BIO001", check_in: "#{work_day} 09:00", check_out: "#{work_day} 18:00" })
      run_import(csv)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.check_in_at).to eq(biometric_checkin)
    end

    it "applies CSV check-out when biometric device only logged check-in" do
      employee = make_employee(code: "BIO002")
      work_day = Date.current

      create(
        :attendance_record,
        user:         employee,
        branch:       branch,
        work_date:    work_day,
        date:         work_day,
        check_in_at:  Time.zone.parse("#{work_day} 07:45:00"),
        check_out_at: nil,
        status:       "incomplete",
        shift_assignment: employee.shift_assignments.first
      )

      csv = build_csv({ code: "BIO002", check_in: "#{work_day} 09:00", check_out: "#{work_day} 18:00" })
      run_import(csv)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.check_out_at).to eq(Time.zone.parse("#{work_day} 18:00:00"))
      expect(record.status).to eq("present")
    end
  end

  # ── Scenario 3: multiple CSV imports for the same day ─────────────────────

  describe "multiple imports for the same employee+day" do
    it "keeps the earliest check-in across two imports" do
      employee = make_employee(code: "MULTI001")
      work_day = Date.current

      # First import: check-in at 09:00
      csv1 = build_csv({ code: "MULTI001", check_in: "#{work_day} 09:00", check_out: "" })
      run_import(csv1)

      # Second import: check-in at 08:00 (earlier — should win)
      csv2 = build_csv({ code: "MULTI001", check_in: "#{work_day} 08:00", check_out: "#{work_day} 17:00" })
      run_import(csv2)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.check_in_at).to eq(Time.zone.parse("#{work_day} 08:00:00"))
      expect(AttendanceRecord.where(user: employee, work_date: work_day).count).to eq(1)
    end

    it "keeps the latest check-out across two imports" do
      employee = make_employee(code: "MULTI002")
      work_day = Date.current

      csv1 = build_csv({ code: "MULTI002", check_in: "#{work_day} 09:00", check_out: "#{work_day} 17:00" })
      run_import(csv1)

      # Second import has later checkout — should update
      csv2 = build_csv({ code: "MULTI002", check_in: "#{work_day} 09:30", check_out: "#{work_day} 18:30" })
      run_import(csv2)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.check_out_at).to eq(Time.zone.parse("#{work_day} 18:30:00"))
    end
  end

  # ── Scenario 4: CSV check-in is earlier than existing ─────────────────────

  describe "CSV has earlier check-in than existing record" do
    it "updates check_in_at to the earlier CSV time" do
      employee = make_employee(code: "EARLY001")
      work_day = Date.current

      create(
        :attendance_record,
        user:        employee,
        branch:      branch,
        work_date:   work_day,
        date:        work_day,
        check_in_at: Time.zone.parse("#{work_day} 09:30:00"),
        shift_assignment: employee.shift_assignments.first
      )

      csv = build_csv({ code: "EARLY001", check_in: "#{work_day} 08:15", check_out: "" })
      run_import(csv)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.check_in_at).to eq(Time.zone.parse("#{work_day} 08:15:00"))
    end
  end

  # ── Scenario 5: CSV checkout is earlier than existing ─────────────────────

  describe "CSV has earlier check-out than existing record" do
    it "preserves the later existing check-out" do
      employee = make_employee(code: "LATE001")
      work_day = Date.current

      create(
        :attendance_record,
        user:         employee,
        branch:       branch,
        work_date:    work_day,
        date:         work_day,
        check_in_at:  Time.zone.parse("#{work_day} 09:00:00"),
        check_out_at: Time.zone.parse("#{work_day} 18:00:00"),
        worked_minutes: 540,
        status:       "present",
        shift_assignment: employee.shift_assignments.first
      )

      # CSV has earlier checkout — should be ignored
      csv = build_csv({ code: "LATE001", check_in: "#{work_day} 09:00", check_out: "#{work_day} 16:00" })
      run_import(csv)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.check_out_at).to eq(Time.zone.parse("#{work_day} 18:00:00"))
    end
  end

  # ── Scenario 6: duplicate import idempotency ──────────────────────────────

  describe "importing the same CSV twice" do
    it "produces identical record state on second import" do
      employee = make_employee(code: "IDEM001")
      work_day = Date.current

      csv = build_csv({ code: "IDEM001", check_in: "#{work_day} 08:00", check_out: "#{work_day} 17:00" })

      run_import(csv)
      record_after_first = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      check_in_first  = record_after_first.check_in_at
      check_out_first = record_after_first.check_out_at
      minutes_first   = record_after_first.worked_minutes

      run_import(csv)
      record_after_second = AttendanceRecord.find_by!(user: employee, work_date: work_day)

      expect(record_after_second.check_in_at).to    eq(check_in_first)
      expect(record_after_second.check_out_at).to   eq(check_out_first)
      expect(record_after_second.worked_minutes).to eq(minutes_first)
    end

    it "does not create extra rows on duplicate import" do
      employee = make_employee(code: "IDEM002")
      work_day = Date.current

      csv = build_csv({ code: "IDEM002", check_in: "#{work_day} 08:00", check_out: "#{work_day} 17:00" })

      expect {
        run_import(csv)
        run_import(csv)
      }.to change(AttendanceRecord, :count).by(1)
    end
  end

  # ── Scenario 7: worked_minutes recalculated from merged timestamps ─────────

  describe "worked_minutes recalculation after merge" do
    it "recalculates worked_minutes from the merged check_in and check_out" do
      employee = make_employee(code: "CALC001")
      work_day = Date.current

      # Existing: checked in at 10:00, no checkout
      create(
        :attendance_record,
        user:         employee,
        branch:       branch,
        work_date:    work_day,
        date:         work_day,
        check_in_at:  Time.zone.parse("#{work_day} 10:00:00"),
        check_out_at: nil,
        worked_minutes: nil,
        status:       "incomplete",
        shift_assignment: employee.shift_assignments.first
      )

      # CSV: checked in at 08:00 (earlier) and out at 17:00
      csv = build_csv({ code: "CALC001", check_in: "#{work_day} 08:00", check_out: "#{work_day} 17:00" })
      run_import(csv)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)

      # Merged: check_in = 08:00, check_out = 17:00 → 540 minutes
      expect(record.check_in_at).to  eq(Time.zone.parse("#{work_day} 08:00:00"))
      expect(record.check_out_at).to eq(Time.zone.parse("#{work_day} 17:00:00"))
      expect(record.worked_minutes).to eq(540)
      expect(record.status).to eq("present")
    end

    it "recalculates worked_minutes using the earliest check_in (not the CSV check_in)" do
      employee = make_employee(code: "CALC002")
      work_day = Date.current

      # Existing: checked in at 07:00, checked out at 16:00 → 540 min
      create(
        :attendance_record,
        user:          employee,
        branch:        branch,
        work_date:     work_day,
        date:          work_day,
        check_in_at:   Time.zone.parse("#{work_day} 07:00:00"),
        check_out_at:  Time.zone.parse("#{work_day} 16:00:00"),
        worked_minutes: 540,
        status:        "present",
        shift_assignment: employee.shift_assignments.first
      )

      # CSV: later check-in (09:00) but later checkout (18:00)
      # Result: check_in stays 07:00 (earlier), check_out becomes 18:00 (later) → 660 min
      csv = build_csv({ code: "CALC002", check_in: "#{work_day} 09:00", check_out: "#{work_day} 18:00" })
      run_import(csv)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.check_in_at).to  eq(Time.zone.parse("#{work_day} 07:00:00"))
      expect(record.check_out_at).to eq(Time.zone.parse("#{work_day} 18:00:00"))
      expect(record.worked_minutes).to eq(660)
    end
  end

  # ── Parse phase: valid row is not rejected due to existing record ──────────

  describe "parse phase — no false 'already exists' errors" do
    it "marks a row valid even when an attendance record already exists for that day" do
      employee = make_employee(code: "PARSE001")
      work_day = Date.current

      create(
        :attendance_record,
        user:        employee,
        branch:      branch,
        work_date:   work_day,
        date:        work_day,
        check_in_at: Time.zone.parse("#{work_day} 09:00:00"),
        shift_assignment: employee.shift_assignments.first
      )

      csv    = build_csv({ code: "PARSE001", check_in: "#{work_day} 08:00", check_out: "" })
      result = described_class.parse(csv, business: business)

      expect(result.headers_valid?).to be true
      row = result.rows.first
      expect(row["valid"]).to be true
      expect(row["errors"]).to be_empty
    end
  end
end
