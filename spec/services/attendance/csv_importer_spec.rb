require "rails_helper"

RSpec.describe Attendance::CsvImporter do
  let(:business) { create(:business, timezone: "UTC") }
  let(:branch)   { create(:branch, business: business) }

  def make_employee(code:, biz: business)
    user  = create(:user, business: biz, employee_code: code)
    shift = create(:shift, :fixed_time, business: biz)
    b     = biz == business ? branch : create(:branch, business: biz)
    create(:shift_assignment, user: user, branch: b, shift: shift,
           effective_from: 1.year.ago.to_date)
    user
  end

  # ── CSV helpers ────────────────────────────────────────────────────────────

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
end
