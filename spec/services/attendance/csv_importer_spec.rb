require "rails_helper"

RSpec.describe Attendance::CsvImporter do
  let(:business) { create(:business, timezone: "UTC") }
  let(:branch)   { create(:branch, business: business) }

  # ── Helpers ────────────────────────────────────────────────────────────────

  # Creates a user with a shift assignment.
  # shift_trait: any FactoryBot shift trait (:fixed_time, :hour_based, :overnight, …)
  def make_employee(code:, biz: business, shift_trait: :fixed_time)
    user  = create(:user, business: biz, employee_code: code)
    shift = create(:shift, shift_trait, business: biz)
    b     = biz == business ? branch : create(:branch, business: biz)
    create(:shift_assignment, user: user, branch: b, shift: shift,
           effective_from: 1.year.ago.to_date)
    user
  end

  def build_csv(*rows)
    header = "employee_code,time\n"
    body   = rows.map { |r| "#{r[:code]},#{r[:time]}" }.join("\n")
    header + body
  end

  def run_import(csv_string, biz: business, user: nil)
    result = described_class.parse(csv_string, business: biz)
    raise "Parse failed: #{result.header_error}" unless result.headers_valid?

    log = AttendanceImportLog.create!(
      business:          biz,
      imported_by:       user || create(:user, business: biz),
      filename:          "test.csv",
      status:            "pending",
      total_rows:        result.total_rows,
      imported_rows:     0,
      failed_rows_count: result.rows.count { |r| !r["valid"] },
      metadata:          { "preview" => result.rows }
    )

    described_class.execute(log)
    log.reload
  end

  # ── Normal IN/OUT pairing ──────────────────────────────────────────────────

  describe "normal IN/OUT pairing" do
    it "pairs first event as check-in and second as check-out" do
      employee = make_employee(code: "EMP001")
      work_day = Date.current

      csv = build_csv(
        { code: "EMP001", time: "#{work_day} 09:00" },
        { code: "EMP001", time: "#{work_day} 17:00" }
      )
      run_import(csv)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.check_in_at).to   eq(Time.zone.parse("#{work_day} 09:00:00"))
      expect(record.check_out_at).to  eq(Time.zone.parse("#{work_day} 17:00:00"))
      expect(record.worked_minutes).to eq(480)
      expect(record.status).to eq("present")
    end

    it "creates an incomplete record when only one punch exists" do
      employee = make_employee(code: "EMP002")
      work_day = Date.current

      csv = build_csv({ code: "EMP002", time: "#{work_day} 09:00" })
      run_import(csv)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.check_in_at).to  eq(Time.zone.parse("#{work_day} 09:00:00"))
      expect(record.check_out_at).to be_nil
      expect(record.status).to eq("incomplete")
    end
  end

  # ── Multiple punches same day ──────────────────────────────────────────────

  describe "multiple punches in the same work day" do
    it "uses first punch as check-in and last OUT for 4 punches" do
      employee = make_employee(code: "MULTI001")
      work_day = Date.current

      csv = build_csv(
        { code: "MULTI001", time: "#{work_day} 09:00" },
        { code: "MULTI001", time: "#{work_day} 12:00" },
        { code: "MULTI001", time: "#{work_day} 13:00" },
        { code: "MULTI001", time: "#{work_day} 17:00" }
      )
      run_import(csv)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.check_in_at).to  eq(Time.zone.parse("#{work_day} 09:00:00"))
      expect(record.check_out_at).to eq(Time.zone.parse("#{work_day} 17:00:00"))
      expect(record.status).to eq("present")
    end

    it "uses second punch as check-out when 3 punches (last event is unmatched IN)" do
      employee = make_employee(code: "MULTI002")
      work_day = Date.current

      csv = build_csv(
        { code: "MULTI002", time: "#{work_day} 09:00" },
        { code: "MULTI002", time: "#{work_day} 13:00" },
        { code: "MULTI002", time: "#{work_day} 14:00" }
      )
      run_import(csv)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.check_in_at).to  eq(Time.zone.parse("#{work_day} 09:00:00"))
      expect(record.check_out_at).to eq(Time.zone.parse("#{work_day} 13:00:00"))
    end

    it "produces one record per employee per work_date regardless of punch count" do
      make_employee(code: "MULTI003")
      work_day = Date.current

      csv = build_csv(
        { code: "MULTI003", time: "#{work_day} 09:00" },
        { code: "MULTI003", time: "#{work_day} 12:30" },
        { code: "MULTI003", time: "#{work_day} 13:30" },
        { code: "MULTI003", time: "#{work_day} 17:30" }
      )
      expect { run_import(csv) }.to change(AttendanceRecord, :count).by(1)
    end

    it "stores punch_count in the preview row" do
      make_employee(code: "MULTI004")
      work_day = Date.current

      csv = build_csv(
        { code: "MULTI004", time: "#{work_day} 09:00" },
        { code: "MULTI004", time: "#{work_day} 12:00" },
        { code: "MULTI004", time: "#{work_day} 13:00" },
        { code: "MULTI004", time: "#{work_day} 17:00" }
      )
      result = described_class.parse(csv, business: business)
      expect(result.rows.first["punch_count"]).to eq(4)
    end
  end

  # ── Unordered rows ─────────────────────────────────────────────────────────

  describe "unordered CSV rows" do
    it "sorts events chronologically before pairing" do
      employee = make_employee(code: "UNORDERED001")
      work_day = Date.current

      csv = build_csv(
        { code: "UNORDERED001", time: "#{work_day} 17:30" },
        { code: "UNORDERED001", time: "#{work_day} 09:15" }
      )
      run_import(csv)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.check_in_at).to  eq(Time.zone.parse("#{work_day} 09:15:00"))
      expect(record.check_out_at).to eq(Time.zone.parse("#{work_day} 17:30:00"))
    end

    it "handles multiple employees interleaved in the CSV" do
      emp1 = make_employee(code: "INTER001")
      emp2 = make_employee(code: "INTER002")
      work_day = Date.current

      csv = build_csv(
        { code: "INTER001", time: "#{work_day} 09:00" },
        { code: "INTER002", time: "#{work_day} 08:30" },
        { code: "INTER001", time: "#{work_day} 17:00" },
        { code: "INTER002", time: "#{work_day} 16:30" }
      )
      run_import(csv)

      r1 = AttendanceRecord.find_by!(user: emp1, work_date: work_day)
      r2 = AttendanceRecord.find_by!(user: emp2, work_date: work_day)

      expect(r1.check_in_at).to  eq(Time.zone.parse("#{work_day} 09:00:00"))
      expect(r1.check_out_at).to eq(Time.zone.parse("#{work_day} 17:00:00"))
      expect(r2.check_in_at).to  eq(Time.zone.parse("#{work_day} 08:30:00"))
      expect(r2.check_out_at).to eq(Time.zone.parse("#{work_day} 16:30:00"))
    end
  end

  # ── Overnight shifts ───────────────────────────────────────────────────────

  describe "overnight shifts" do
    let(:night_business) { create(:business, timezone: "Asia/Riyadh", business_day_start_hour: 6) }

    it "attributes a post-midnight event before business_day_start_hour to the previous work_date" do
      make_employee(code: "NIGHT001", biz: night_business)

      # 23:00 on the 24th and 01:00 on the 25th are both before start_hour=6
      # so both belong to work_date 2026-05-24
      csv = "employee_code,time\n" \
            "NIGHT001,2026-05-24 23:00:00\n" \
            "NIGHT001,2026-05-25 01:00:00\n"

      result = described_class.parse(csv, business: night_business)

      expect(result.headers_valid?).to be true
      expect(result.rows.count { |r| r["valid"] }).to eq(1)
      expect(result.rows.first["work_date"]).to eq("2026-05-24")
    end

    it "creates one record spanning midnight for an overnight shift" do
      employee = make_employee(code: "NIGHT002", biz: night_business)

      csv = "employee_code,time\n" \
            "NIGHT002,2026-05-24 22:00:00\n" \
            "NIGHT002,2026-05-25 06:00:00\n"

      run_import(csv, biz: night_business)

      tz      = ActiveSupport::TimeZone["Asia/Riyadh"]
      in_time = tz.parse("2026-05-24 22:00:00")

      record = AttendanceRecord.find_by!(user: employee, work_date: Date.new(2026, 5, 24))
      expect(record.check_in_at).to eq(in_time)
    end
  end

  # ── Timezone handling ──────────────────────────────────────────────────────

  describe "timezone handling" do
    it "parses datetime strings in the business timezone, not UTC" do
      tz_biz   = create(:business, timezone: "Asia/Riyadh")
      employee = create(:user, business: tz_biz, employee_code: "TZ001")
      create(:shift_assignment,
             user: employee,
             branch: create(:branch, business: tz_biz),
             shift: create(:shift, :fixed_time, business: tz_biz),
             effective_from: 1.year.ago.to_date)

      csv = "employee_code,time\nTZ001,2026-05-24 09:00:00\nTZ001,2026-05-24 17:00:00\n"
      run_import(csv, biz: tz_biz)

      record = AttendanceRecord.find_by!(user: employee, work_date: Date.new(2026, 5, 24))
      riyadh = ActiveSupport::TimeZone["Asia/Riyadh"]
      expect(record.check_in_at.in_time_zone(riyadh).hour).to eq(9)
      expect(record.check_out_at.in_time_zone(riyadh).hour).to eq(17)
    end
  end

  # ── Duplicate import idempotency ──────────────────────────────────────────

  describe "importing the same CSV twice" do
    it "produces identical record state on second import" do
      employee = make_employee(code: "IDEM001")
      work_day = Date.current

      csv = build_csv(
        { code: "IDEM001", time: "#{work_day} 08:00" },
        { code: "IDEM001", time: "#{work_day} 17:00" }
      )

      run_import(csv)
      first  = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      in1    = first.check_in_at
      out1   = first.check_out_at
      mins1  = first.worked_minutes

      run_import(csv)
      second = AttendanceRecord.find_by!(user: employee, work_date: work_day)

      expect(second.check_in_at).to    eq(in1)
      expect(second.check_out_at).to   eq(out1)
      expect(second.worked_minutes).to eq(mins1)
    end

    it "does not create extra records on duplicate import" do
      make_employee(code: "IDEM002")
      work_day = Date.current

      csv = build_csv(
        { code: "IDEM002", time: "#{work_day} 08:00" },
        { code: "IDEM002", time: "#{work_day} 17:00" }
      )

      expect {
        run_import(csv)
        run_import(csv)
      }.to change(AttendanceRecord, :count).by(1)
    end

    it "marks skipped_records in metadata when nothing changed" do
      make_employee(code: "IDEM003")
      work_day = Date.current

      csv = build_csv(
        { code: "IDEM003", time: "#{work_day} 08:00" },
        { code: "IDEM003", time: "#{work_day} 17:00" }
      )

      run_import(csv)
      log = run_import(csv)

      expect(log.metadata["skipped_records"]).to eq(1)
      expect(log.metadata["created_records"]).to  eq(0)
      expect(log.metadata["updated_records"]).to  eq(0)
    end
  end

  # ── Merging with existing records ──────────────────────────────────────────

  describe "merging with existing records (biometric / mobile)" do
    it "preserves the earlier check-in from an existing record" do
      employee = make_employee(code: "MERGE001")
      work_day = Date.current

      create(:attendance_record,
             user:             employee,
             branch:           branch,
             work_date:        work_day,
             date:             work_day,
             check_in_at:      Time.zone.parse("#{work_day} 08:00:00"),
             shift_assignment: employee.shift_assignments.first)

      csv = build_csv(
        { code: "MERGE001", time: "#{work_day} 09:00" },
        { code: "MERGE001", time: "#{work_day} 17:00" }
      )
      run_import(csv)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.check_in_at).to  eq(Time.zone.parse("#{work_day} 08:00:00"))
      expect(record.check_out_at).to eq(Time.zone.parse("#{work_day} 17:00:00"))
    end

    it "applies CSV check-out when existing record had no check-out" do
      employee = make_employee(code: "MERGE002")
      work_day = Date.current

      create(:attendance_record,
             user:             employee,
             branch:           branch,
             work_date:        work_day,
             date:             work_day,
             check_in_at:      Time.zone.parse("#{work_day} 07:45:00"),
             check_out_at:     nil,
             status:           "incomplete",
             shift_assignment: employee.shift_assignments.first)

      csv = build_csv(
        { code: "MERGE002", time: "#{work_day} 09:00" },
        { code: "MERGE002", time: "#{work_day} 18:00" }
      )
      run_import(csv)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.check_out_at).to eq(Time.zone.parse("#{work_day} 18:00:00"))
      expect(record.status).to       eq("present")
    end

    it "does not create a duplicate when an existing record already covers the day" do
      employee = make_employee(code: "MERGE003")
      work_day = Date.current

      create(:attendance_record,
             user:             employee,
             branch:           branch,
             work_date:        work_day,
             date:             work_day,
             check_in_at:      Time.zone.parse("#{work_day} 08:00:00"),
             shift_assignment: employee.shift_assignments.first)

      csv = build_csv({ code: "MERGE003", time: "#{work_day} 09:00" })
      expect { run_import(csv) }.not_to change(AttendanceRecord, :count)
    end

    it "preserves the later existing check-out if CSV check-out is earlier" do
      employee = make_employee(code: "MERGE004")
      work_day = Date.current

      create(:attendance_record,
             user:             employee,
             branch:           branch,
             work_date:        work_day,
             date:             work_day,
             check_in_at:      Time.zone.parse("#{work_day} 09:00:00"),
             check_out_at:     Time.zone.parse("#{work_day} 18:00:00"),
             worked_minutes:   540,
             status:           "present",
             shift_assignment: employee.shift_assignments.first)

      csv = build_csv(
        { code: "MERGE004", time: "#{work_day} 09:00" },
        { code: "MERGE004", time: "#{work_day} 16:00" }
      )
      run_import(csv)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.check_out_at).to eq(Time.zone.parse("#{work_day} 18:00:00"))
    end
  end

  # ── Import summary ─────────────────────────────────────────────────────────

  describe "import summary metadata" do
    it "records created_records for a brand-new record" do
      make_employee(code: "SUM001")
      work_day = Date.current

      csv = build_csv(
        { code: "SUM001", time: "#{work_day} 09:00" },
        { code: "SUM001", time: "#{work_day} 17:00" }
      )
      log = run_import(csv)

      expect(log.metadata["created_records"]).to eq(1)
      expect(log.metadata["updated_records"]).to eq(0)
      expect(log.metadata["skipped_records"]).to eq(0)
      expect(log.imported_rows).to eq(1)
    end

    it "records updated_records when timestamps improve an existing record" do
      employee = make_employee(code: "SUM002")
      work_day = Date.current

      create(:attendance_record,
             user:             employee,
             branch:           branch,
             work_date:        work_day,
             date:             work_day,
             check_in_at:      Time.zone.parse("#{work_day} 09:00:00"),
             check_out_at:     nil,
             status:           "incomplete",
             shift_assignment: employee.shift_assignments.first)

      csv = build_csv(
        { code: "SUM002", time: "#{work_day} 09:00" },
        { code: "SUM002", time: "#{work_day} 17:00" }
      )
      log = run_import(csv)

      expect(log.metadata["updated_records"]).to eq(1)
      expect(log.metadata["created_records"]).to eq(0)
      expect(log.imported_rows).to eq(1)
    end
  end

  # ── Parse validation ──────────────────────────────────────────────────────

  describe "parse phase — header validation" do
    it "rejects the old format with check_in_at / check_out_at columns" do
      csv = "employee_code,check_in_at,check_out_at\n" \
            "EMP001,2026-05-24 09:00,2026-05-24 17:00\n"
      result = described_class.parse(csv, business: business)

      expect(result.headers_valid?).to be false
      expect(result.header_error).to include("Old format detected")
    end

    it "rejects a CSV missing the time column" do
      result = described_class.parse("employee_code\nEMP001\n", business: business)

      expect(result.headers_valid?).to be false
      expect(result.header_error).to   include("time")
    end
  end

  describe "parse phase — row validation" do
    it "marks a row invalid for an unknown employee_code" do
      csv    = "employee_code,time\nUNKNOWN,2026-05-24 09:00\n"
      result = described_class.parse(csv, business: business)

      expect(result.rows.first["valid"]).to  be false
      expect(result.rows.first["errors"].first).to include("not found")
    end

    it "marks a row invalid for an unparseable datetime" do
      make_employee(code: "BAD001")
      csv    = "employee_code,time\nBAD001,not-a-date\n"
      result = described_class.parse(csv, business: business)

      expect(result.rows.first["valid"]).to be false
      expect(result.rows.first["errors"].first).to include("not a valid datetime")
    end

    it "total_rows counts raw punch events, not paired records" do
      make_employee(code: "COUNT001")
      work_day = Date.current

      csv    = build_csv(
        { code: "COUNT001", time: "#{work_day} 09:00" },
        { code: "COUNT001", time: "#{work_day} 17:00" }
      )
      result = described_class.parse(csv, business: business)

      expect(result.total_rows).to                            eq(2)
      expect(result.rows.count { |r| r["valid"] }).to         eq(1)
    end

    it "does not reject a row because an attendance record already exists for that day" do
      employee = make_employee(code: "PARSE001")
      work_day = Date.current

      create(:attendance_record,
             user:             employee,
             branch:           branch,
             work_date:        work_day,
             date:             work_day,
             check_in_at:      Time.zone.parse("#{work_day} 09:00:00"),
             shift_assignment: employee.shift_assignments.first)

      csv    = build_csv({ code: "PARSE001", time: "#{work_day} 08:00" })
      result = described_class.parse(csv, business: business)

      expect(result.rows.first["valid"]).to  be true
      expect(result.rows.first["errors"]).to be_empty
    end

    it "deduplicates exact-same timestamps for the same employee and day" do
      make_employee(code: "DEDUP001")
      work_day = Date.current

      csv = build_csv(
        { code: "DEDUP001", time: "#{work_day} 09:00" },
        { code: "DEDUP001", time: "#{work_day} 09:00" },
        { code: "DEDUP001", time: "#{work_day} 17:00" }
      )
      result = described_class.parse(csv, business: business)
      # After dedup: 2 unique punches → 1 paired record (IN + OUT)
      paired = result.rows.select { |r| r["valid"] }
      expect(paired.size).to            eq(1)
      expect(paired.first["punch_count"]).to eq(2)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # REGRESSION: Canonical pipeline parity
  #
  # These specs verify that CSV imports use the same TimeCalculator logic as
  # PunchService, CheckInService, CheckOutService, and AdjustmentService so that
  # late_minutes, early_leave_minutes, worked_minutes, and status are identical
  # regardless of how the attendance record was created.
  # ═══════════════════════════════════════════════════════════════════════════

  describe "penalty field computation — canonical pipeline parity" do
    # Shift factory :fixed_time → start_time 09:00, end_time 17:00
    # These tests rely on a UTC business so times are unambiguous.

    it "sets zero penalties for on-time full-shift import" do
      employee = make_employee(code: "CANON001")
      work_day = Date.current

      csv = build_csv(
        { code: "CANON001", time: "#{work_day} 09:00" },
        { code: "CANON001", time: "#{work_day} 17:00" }
      )
      run_import(csv)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.late_minutes).to        eq(0)
      expect(record.early_leave_minutes).to eq(0)
      expect(record.worked_minutes).to      eq(480)
      expect(record.status).to              eq("present")
    end

    # ── Lateness ─────────────────────────────────────────────────────────────

    it "sets late_minutes when check-in is after shift start" do
      employee = make_employee(code: "LATE001")  # shift 09:00–17:00
      work_day = Date.current

      csv = build_csv(
        { code: "LATE001", time: "#{work_day} 09:30" },  # 30 minutes late
        { code: "LATE001", time: "#{work_day} 17:00" }
      )
      run_import(csv)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.late_minutes).to        eq(30)
      expect(record.early_leave_minutes).to eq(0)
      expect(record.worked_minutes).to      eq(450)
      expect(record.status).to              eq("late")
    end

    it "sets status to 'late' for a single late punch with no checkout" do
      employee = make_employee(code: "LATEIN001")  # shift 09:00–17:00
      work_day = Date.current

      # Before fix: status was always "incomplete" for single-punch imports.
      # Now it must reflect lateness just like PunchService does.
      csv = build_csv({ code: "LATEIN001", time: "#{work_day} 09:45" })  # 45 minutes late
      run_import(csv)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.late_minutes).to   eq(45)
      expect(record.worked_minutes).to be_nil
      expect(record.status).to         eq("late")
    end

    it "does not set late_minutes for an early check-in (before shift start)" do
      employee = make_employee(code: "EARLY_IN001")  # shift 09:00–17:00
      work_day = Date.current

      csv = build_csv(
        { code: "EARLY_IN001", time: "#{work_day} 08:30" },  # 30 min early → not late
        { code: "EARLY_IN001", time: "#{work_day} 17:00" }
      )
      run_import(csv)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.late_minutes).to eq(0)
      expect(record.status).to       eq("present")
    end

    # ── Early leave ───────────────────────────────────────────────────────────

    it "sets early_leave_minutes when check-out is before shift end" do
      employee = make_employee(code: "EARLYOUT001")  # shift 09:00–17:00
      work_day = Date.current

      csv = build_csv(
        { code: "EARLYOUT001", time: "#{work_day} 09:00" },
        { code: "EARLYOUT001", time: "#{work_day} 16:00" }  # 60 minutes early
      )
      run_import(csv)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.late_minutes).to        eq(0)
      expect(record.early_leave_minutes).to eq(60)
      expect(record.worked_minutes).to      eq(420)
      expect(record.status).to              eq("early_leave")
    end

    it "sets status to 'late' (not 'early_leave') when both penalties apply" do
      # TimeCalculator.derive_status: late takes precedence over early_leave
      employee = make_employee(code: "BOTH001")  # shift 09:00–17:00
      work_day = Date.current

      csv = build_csv(
        { code: "BOTH001", time: "#{work_day} 09:30" },  # 30 min late
        { code: "BOTH001", time: "#{work_day} 16:00" }   # 60 min early leave
      )
      run_import(csv)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.late_minutes).to        eq(30)
      expect(record.early_leave_minutes).to eq(60)
      expect(record.status).to              eq("late")
    end

    # ── Hour-based shifts ─────────────────────────────────────────────────────

    it "computes early_leave_minutes against required_hours for hour-based shifts" do
      # :hour_based shift has required_hours: 8.0, no start/end times
      employee = make_employee(code: "HOUR001", shift_trait: :hour_based)
      work_day = Date.current

      # Works only 7 h (420 min) of the required 8 h (480 min) → 60 min shortfall
      csv = build_csv(
        { code: "HOUR001", time: "#{work_day} 09:00" },
        { code: "HOUR001", time: "#{work_day} 16:00" }
      )
      run_import(csv)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.worked_minutes).to      eq(420)
      expect(record.early_leave_minutes).to eq(60)
      expect(record.status).to              eq("early_leave")
    end

    it "sets zero early_leave_minutes for a full-hours hour-based shift" do
      employee = make_employee(code: "HOUR002", shift_trait: :hour_based)
      work_day = Date.current

      # Exactly 8 hours → no shortfall
      csv = build_csv(
        { code: "HOUR002", time: "#{work_day} 09:00" },
        { code: "HOUR002", time: "#{work_day} 17:00" }
      )
      run_import(csv)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.worked_minutes).to      eq(480)
      expect(record.early_leave_minutes).to eq(0)
      expect(record.status).to              eq("present")
    end

    # ── Overnight shifts ──────────────────────────────────────────────────────

    describe "overnight shift penalty computation" do
      # :overnight factory trait → start_time 13:00, end_time 01:00 (next day)
      let(:night_biz) { create(:business, timezone: "UTC", business_day_start_hour: 6) }

      it "computes late_minutes for a late check-in on an overnight shift" do
        employee = make_employee(code: "NLATE001", biz: night_biz, shift_trait: :overnight)

        # Overnight shift starts 13:00; employee arrives at 13:30 → 30 min late
        csv = "employee_code,time\n" \
              "NLATE001,2026-05-24 13:30:00\n" \
              "NLATE001,2026-05-25 01:00:00\n"

        run_import(csv, biz: night_biz)

        record = AttendanceRecord.find_by!(user: employee, work_date: Date.new(2026, 5, 24))
        expect(record.late_minutes).to eq(30)
        expect(record.status).to       eq("late")
      end

      it "computes early_leave_minutes for an early checkout on an overnight shift" do
        employee = make_employee(code: "NEARLY001", biz: night_biz, shift_trait: :overnight)

        # Shift: 13:00–01:00 (12 hours). Checkout at 00:00 → 60 min early.
        csv = "employee_code,time\n" \
              "NEARLY001,2026-05-24 13:00:00\n" \
              "NEARLY001,2026-05-25 00:00:00\n"

        run_import(csv, biz: night_biz)

        record = AttendanceRecord.find_by!(user: employee, work_date: Date.new(2026, 5, 24))
        expect(record.early_leave_minutes).to eq(60)
        expect(record.status).to              eq("early_leave")
      end

      it "sets zero penalties for a full overnight shift" do
        employee = make_employee(code: "NFULL001", biz: night_biz, shift_trait: :overnight)

        # Shift: 13:00–01:00. Check-in 13:00, check-out 01:00 → no penalties.
        csv = "employee_code,time\n" \
              "NFULL001,2026-05-24 13:00:00\n" \
              "NFULL001,2026-05-25 01:00:00\n"

        run_import(csv, biz: night_biz)

        record = AttendanceRecord.find_by!(user: employee, work_date: Date.new(2026, 5, 24))
        expect(record.late_minutes).to        eq(0)
        expect(record.early_leave_minutes).to eq(0)
        expect(record.status).to              eq("present")
        expect(record.worked_minutes).to      eq(720)
      end
    end

    # ── Cross-timezone business ───────────────────────────────────────────────

    describe "cross-timezone lateness detection" do
      it "evaluates lateness in the business timezone, not UTC" do
        # Business in Riyadh (UTC+3), shift 09:00–17:00 Riyadh local.
        # CSV times are interpreted as Riyadh local → 09:30 Riyadh = late by 30 min.
        tz_biz   = create(:business, timezone: "Asia/Riyadh")
        employee = create(:user, business: tz_biz, employee_code: "TZLATE001")
        b        = create(:branch, business: tz_biz)
        shift    = create(:shift, :fixed_time, business: tz_biz)  # 09:00–17:00
        create(:shift_assignment, user: employee, branch: b, shift: shift,
               effective_from: 1.year.ago.to_date)

        csv = "employee_code,time\nTZLATE001,2026-05-24 09:30:00\nTZLATE001,2026-05-24 17:00:00\n"
        run_import(csv, biz: tz_biz)

        record = AttendanceRecord.find_by!(user: employee, work_date: Date.new(2026, 5, 24))
        expect(record.late_minutes).to eq(30)
        expect(record.status).to       eq("late")
      end
    end

    # ── Recomputation on update ───────────────────────────────────────────────

    it "recomputes penalty fields when updating an existing record with a new check-out" do
      # An existing record with a late check-in (set by biometric earlier).
      # CSV adds a check-out that triggers early_leave — both fields must be correct.
      employee = make_employee(code: "RECOMP001")  # shift 09:00–17:00
      work_day = Date.current

      create(:attendance_record,
             user:             employee,
             branch:           branch,
             work_date:        work_day,
             date:             work_day,
             check_in_at:      Time.zone.parse("#{work_day} 09:30:00"),
             check_out_at:     nil,
             late_minutes:     30,
             status:           "late",
             shift_assignment: employee.shift_assignments.first)

      # CSV check-in matches existing → not updated. Check-out 16:00 is new.
      csv = build_csv(
        { code: "RECOMP001", time: "#{work_day} 09:30" },
        { code: "RECOMP001", time: "#{work_day} 16:00" }
      )
      run_import(csv)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.late_minutes).to        eq(30)          # correctly preserved
      expect(record.early_leave_minutes).to eq(60)          # newly computed
      expect(record.worked_minutes).to      eq(390)         # 09:30–16:00 = 390 min
      expect(record.status).to              eq("late")      # late takes precedence
    end

    it "does not update existing records when CSV adds no new information" do
      # When an existing record is unchanged, worked_minutes / status must not
      # be silently corrupted (the old importer did status = 'present' blindly).
      employee = make_employee(code: "NOCHANGE001")  # shift 09:00–17:00
      work_day = Date.current

      create(:attendance_record,
             user:             employee,
             branch:           branch,
             work_date:        work_day,
             date:             work_day,
             check_in_at:      Time.zone.parse("#{work_day} 09:30:00"),
             check_out_at:     Time.zone.parse("#{work_day} 17:00:00"),
             worked_minutes:   450,
             late_minutes:     30,
             early_leave_minutes: 0,
             status:           "late",
             shift_assignment: employee.shift_assignments.first)

      # Identical punches — nothing should change
      csv = build_csv(
        { code: "NOCHANGE001", time: "#{work_day} 09:30" },
        { code: "NOCHANGE001", time: "#{work_day} 17:00" }
      )
      run_import(csv)

      record = AttendanceRecord.find_by!(user: employee, work_date: work_day)
      expect(record.late_minutes).to   eq(30)
      expect(record.status).to         eq("late")
      expect(record.worked_minutes).to eq(450)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # REGRESSION: Payroll regeneration after import
  #
  # When a CSV import creates or updates attendance records, any existing *draft*
  # payroll period for the business+month must be regenerated so payslips reflect
  # the newly-imported data. Non-draft (finalized, paid, under_review) periods
  # must NOT be touched — they are immutable.
  # ═══════════════════════════════════════════════════════════════════════════

  describe "payroll regeneration after import" do
    it "regenerates an existing draft payroll period that covers the imported work_dates" do
      employee = make_employee(code: "PAY001")
      work_day = Date.current

      create(:payroll_period, business: business,
             period_year: work_day.year, period_month: work_day.month,
             status: :draft)

      expect(Payroll::PeriodGenerator).to receive(:call).with(
        business:     business,
        year:         work_day.year,
        month:        work_day.month,
        generated_by: anything
      )

      csv = build_csv(
        { code: "PAY001", time: "#{work_day} 09:00" },
        { code: "PAY001", time: "#{work_day} 17:00" }
      )
      run_import(csv)
    end

    it "does not regenerate a finalized payroll period" do
      make_employee(code: "PAY002")
      work_day = Date.current

      create(:payroll_period, business: business,
             period_year: work_day.year, period_month: work_day.month,
             status: :finalized)

      expect(Payroll::PeriodGenerator).not_to receive(:call)

      csv = build_csv(
        { code: "PAY002", time: "#{work_day} 09:00" },
        { code: "PAY002", time: "#{work_day} 17:00" }
      )
      run_import(csv)
    end

    it "does not regenerate a paid payroll period" do
      make_employee(code: "PAY003")
      work_day = Date.current

      create(:payroll_period, business: business,
             period_year: work_day.year, period_month: work_day.month,
             status: :paid)

      expect(Payroll::PeriodGenerator).not_to receive(:call)

      csv = build_csv(
        { code: "PAY003", time: "#{work_day} 09:00" },
        { code: "PAY003", time: "#{work_day} 17:00" }
      )
      run_import(csv)
    end

    it "does not regenerate when no payroll period exists for the month" do
      make_employee(code: "PAY004")
      work_day = Date.current

      expect(Payroll::PeriodGenerator).not_to receive(:call)

      csv = build_csv(
        { code: "PAY004", time: "#{work_day} 09:00" },
        { code: "PAY004", time: "#{work_day} 17:00" }
      )
      run_import(csv)
    end

    it "does not regenerate on re-import when all records are unchanged (skipped)" do
      make_employee(code: "PAY005")
      work_day = Date.current

      create(:payroll_period, business: business,
             period_year: work_day.year, period_month: work_day.month,
             status: :draft)

      csv = build_csv(
        { code: "PAY005", time: "#{work_day} 09:00" },
        { code: "PAY005", time: "#{work_day} 17:00" }
      )
      run_import(csv)  # first import creates the record

      # Second import is identical → all records skipped → no regeneration
      expect(Payroll::PeriodGenerator).not_to receive(:call)
      run_import(csv)
    end

    it "regenerates when an existing incomplete record gains a check-out from the import" do
      employee = make_employee(code: "PAY006")
      work_day = Date.current

      create(:attendance_record,
             user:             employee,
             branch:           branch,
             work_date:        work_day,
             date:             work_day,
             check_in_at:      Time.zone.parse("#{work_day} 09:00:00"),
             check_out_at:     nil,
             status:           "incomplete",
             shift_assignment: employee.shift_assignments.first)

      create(:payroll_period, business: business,
             period_year: work_day.year, period_month: work_day.month,
             status: :draft)

      expect(Payroll::PeriodGenerator).to receive(:call)

      csv = build_csv(
        { code: "PAY006", time: "#{work_day} 09:00" },
        { code: "PAY006", time: "#{work_day} 17:00" }  # adds the missing checkout
      )
      run_import(csv)
    end

    it "regenerates only once per month even when multiple employees are imported" do
      make_employee(code: "PAY007")
      make_employee(code: "PAY008")
      work_day = Date.current

      create(:payroll_period, business: business,
             period_year: work_day.year, period_month: work_day.month,
             status: :draft)

      # Two employees imported in the same month → PeriodGenerator called exactly once
      expect(Payroll::PeriodGenerator).to receive(:call).once

      csv = build_csv(
        { code: "PAY007", time: "#{work_day} 09:00" },
        { code: "PAY007", time: "#{work_day} 17:00" },
        { code: "PAY008", time: "#{work_day} 09:00" },
        { code: "PAY008", time: "#{work_day} 17:00" }
      )
      run_import(csv)
    end

    it "regenerates separately for each distinct month when import spans multiple months" do
      make_employee(code: "PAY009")
      month1 = Date.new(2026, 4, 28)
      month2 = Date.new(2026, 5, 2)

      create(:payroll_period, business: business,
             period_year: 2026, period_month: 4, status: :draft)
      create(:payroll_period, business: business,
             period_year: 2026, period_month: 5, status: :draft)

      expect(Payroll::PeriodGenerator).to receive(:call).twice

      csv = "employee_code,time\n" \
            "PAY009,2026-04-28 09:00:00\n" \
            "PAY009,2026-04-28 17:00:00\n" \
            "PAY009,2026-05-02 09:00:00\n" \
            "PAY009,2026-05-02 17:00:00\n"
      run_import(csv)
    end
  end
end
