require "csv"

module Attendance
  # Parses and imports attendance records from a CSV file containing sequential
  # punch events (one "time" column per row).
  #
  # Two-phase operation:
  #   1. parse(csv_data, business:)  — validates events, groups/pairs into records,
  #                                    returns ParseResult for preview
  #   2. execute(import_log)         — commits valid paired rows from a pending import log
  #
  # CSV format:
  #   employee_code,time
  #   EMP001,2026-05-24 09:01:00
  #   EMP001,2026-05-24 17:04:00
  #
  # Pairing logic (per employee per work_date):
  #   Events sorted chronologically. 0-indexed: even positions (0,2,4...) = check-in,
  #   odd positions (1,3,5...) = check-out. The resulting AttendanceRecord uses
  #   the first event as check_in and the last OUT event as check_out.
  #
  # work_date is computed with BusinessDay.work_date_for so overnight-shift employees
  # whose post-midnight events fall before business_day_start_hour are attributed to
  # the correct work date.
  #
  # Canonical pipeline guarantee:
  #   execute uses the same TimeCalculator methods as PunchService, CheckInService,
  #   CheckOutService, and AdjustmentService so that late_minutes, early_leave_minutes,
  #   and status are always identical regardless of how a record was created.
  #   After persisting records it also regenerates any existing *draft* payroll periods
  #   whose month was touched by the import.
  class CsvImporter
    REQUIRED_COLUMNS = %w[employee_code time].freeze
    LEGACY_COLUMNS   = %w[check_in_at check_out_at].freeze
    DATETIME_FORMATS = [
      "%Y-%m-%d %H:%M",
      "%Y-%m-%d %H:%M:%S",
      "%d/%m/%Y %H:%M",
      "%d/%m/%Y %H:%M:%S"
    ].freeze

    ParseResult = Struct.new(:rows, :total_rows, :headers_valid, :header_error, keyword_init: true) do
      def headers_valid? = headers_valid
    end

    def self.parse(csv_data, business:)
      new(business: business).parse(csv_data)
    end

    def self.execute(import_log)
      new(business: import_log.business).execute(import_log)
    end

    def initialize(business:)
      @business = business
    end

    # ── Phase 1: parse & validate ─────────────────────────────────────────────

    def parse(csv_data)
      table = CSV.parse(
        csv_data.encode("UTF-8", invalid: :replace, undef: :replace, replace: ""),
        headers:     true,
        skip_blanks: true,
        strip:       true
      )

      headers = table.headers.map { |h| h.to_s.strip.downcase }

      if (LEGACY_COLUMNS & headers).any?
        return ParseResult.new(
          rows:          [],
          total_rows:    0,
          headers_valid: false,
          header_error:  "Old format detected (check_in_at / check_out_at columns). " \
                         "Please use the new format: employee_code, time"
        )
      end

      missing = REQUIRED_COLUMNS - headers
      if missing.any?
        return ParseResult.new(
          rows:          [],
          total_rows:    0,
          headers_valid: false,
          header_error:  "Missing required columns: #{missing.join(', ')}"
        )
      end

      total_punch_events = 0
      invalid_rows       = []
      valid_punches      = []

      table.each_with_index do |row, i|
        row_number    = i + 2
        employee_code = row["employee_code"]&.strip
        time_str      = row["time"]&.strip
        total_punch_events += 1

        errs      = []
        user      = nil
        timestamp = nil

        if employee_code.blank?
          errs << "employee_code is required"
        else
          user = @business.users.find_by(employee_code: employee_code)
          errs << "Employee '#{employee_code}' not found" unless user
        end

        if time_str.blank?
          errs << "time is required"
        else
          timestamp = try_parse(time_str)
          errs << "time '#{time_str}' is not a valid datetime" unless timestamp
        end

        if errs.any?
          invalid_rows << {
            "row"           => row_number,
            "employee_code" => employee_code.presence || "",
            "time"          => time_str.presence || "",
            "valid"         => false,
            "errors"        => errs
          }
        else
          valid_punches << {
            row_number:    row_number,
            employee_code: employee_code,
            user:          user,
            timestamp:     timestamp
          }
        end
      end

      paired_rows = pair_punches(valid_punches)
      all_rows    = (paired_rows + invalid_rows).sort_by { |r| r["row"] }

      ParseResult.new(
        rows:          all_rows,
        total_rows:    total_punch_events,
        headers_valid: true,
        header_error:  nil
      )
    end

    # ── Phase 2: commit ───────────────────────────────────────────────────────
    #
    # Uses the same canonical pipeline as PunchService / AdjustmentService:
    #   - Shifts::AssignmentFinder for shift lookup
    #   - TimeCalculator.late_minutes / early_leave_minutes / derive_status
    #   - Payroll::PeriodGenerator for any draft payroll periods that are touched
    def execute(import_log)
      valid_rows      = import_log.valid_preview_rows
      created         = 0
      updated         = 0
      skipped         = 0
      runtime_fails   = []
      affected_months = []   # [[year, month], ...] for payroll regeneration

      valid_rows.each do |row|
        begin
          user      = @business.users.find_by!(employee_code: row["employee_code"])
          check_in  = parse_datetime(row["check_in_at"])
          check_out = row["check_out_at"].present? ? parse_datetime(row["check_out_at"]) : nil
          work_date = Date.parse(row["work_date"])

          # Use the canonical assignment finder (same as PunchService and CheckInService)
          assignment = Shifts::AssignmentFinder.for(user: user, date: work_date)

          record = AttendanceRecord.find_or_initialize_by(user_id: user.id, work_date: work_date)
          is_new  = record.new_record?

          if is_new
            record.date             = work_date
            record.branch           = assignment&.branch   # object, not just ID
            record.shift_assignment = assignment
          end

          prev_in  = record.check_in_at
          prev_out = record.check_out_at

          # Keep the earliest check-in across sources (CSV vs existing biometric/mobile)
          if is_new || check_in < record.check_in_at
            record.check_in_at     = check_in
            record.check_in_source = "import"
          end

          # Keep the latest check-out across sources
          if check_out.present? && (record.check_out_at.nil? || check_out > record.check_out_at)
            record.check_out_at     = check_out
            record.check_out_source = "import"
          end

          timestamps_changed = is_new ||
                               record.check_in_at  != prev_in  ||
                               record.check_out_at != prev_out

          if timestamps_changed
            # Delegate to the shared RecordRecomputer so the exact same
            # TimeCalculator logic runs here and in HistoricalBackfill.
            RecordRecomputer.recompute!(record)
            record.save!

            if is_new
              created += 1
            else
              updated += 1
            end
            affected_months << [work_date.year, work_date.month]
          else
            skipped += 1
          end

        rescue => e
          Rails.logger.warn("[CsvImporter] Row error business=#{@business.id}: #{e.class}: #{e.message}")
          runtime_fails << row.merge("error" => e.message)
        end
      end

      total_failed = import_log.failed_rows_count + runtime_fails.size
      import_log.update!(
        status:            "completed",
        imported_rows:     created + updated,
        failed_rows_count: total_failed,
        metadata:          import_log.metadata.merge(
          "failed"          => runtime_fails,
          "created_records" => created,
          "updated_records" => updated,
          "skipped_records" => skipped
        )
      )

      # Regenerate any existing *draft* payroll periods whose month was touched.
      # Does NOT create new payroll periods — only recalculates existing ones so
      # the freshly-imported attendance is reflected in pending payslips.
      regenerate_affected_payrolls(affected_months.uniq, triggered_by: import_log.imported_by)
    end

    private

    # ── Post-import payroll refresh ───────────────────────────────────────────

    def regenerate_affected_payrolls(affected_months, triggered_by:)
      return if affected_months.empty?

      Payroll::DraftRegenerator.call(
        business:     @business,
        months:       affected_months,
        triggered_by: triggered_by
      )
    end

    # ── Punch-pairing ─────────────────────────────────────────────────────────

    # Groups punch events by (user_id, work_date) using BusinessDay logic,
    # sorts chronologically, deduplicates exact timestamps, then pairs:
    #   index 0 → check-in, index 1 → check-out, index 2 → check-in, …
    # The record uses the first event as check_in and the last OUT event
    # (last odd-indexed position) as check_out.
    def pair_punches(punches)
      groups = punches.group_by do |p|
        work_date = BusinessDay.work_date_for(p[:timestamp], context: @business)
        [ p[:user].id, work_date ]
      end

      groups.map do |(user_id, work_date), group|
        user   = group.first[:user]
        sorted = group.sort_by { |p| p[:timestamp] }
                      .uniq { |p| p[:timestamp] }

        check_in = sorted.first[:timestamp]

        # Last OUT is at the last odd 0-based index (1, 3, 5...).
        # For n events: last odd index = n-1 if n is even, n-2 if n is odd.
        last_out_idx = sorted.size.even? ? sorted.size - 1 : sorted.size - 2
        check_out    = last_out_idx >= 1 ? sorted[last_out_idx][:timestamp] : nil

        {
          "row"           => sorted.first[:row_number],
          "employee_code" => sorted.first[:employee_code],
          "employee_name" => user.full_name,
          "check_in_at"   => check_in.strftime("%Y-%m-%d %H:%M:%S"),
          "check_out_at"  => check_out&.strftime("%Y-%m-%d %H:%M:%S"),
          "work_date"     => work_date.to_s,
          "punch_count"   => sorted.size,
          "valid"         => true,
          "errors"        => []
        }
      end
    end

    # ── Time parsing ──────────────────────────────────────────────────────────

    def try_parse(str)
      tz = ActiveSupport::TimeZone[@business.timezone] || ActiveSupport::TimeZone["UTC"]
      DATETIME_FORMATS.each do |fmt|
        parsed = DateTime.strptime(str, fmt) rescue next
        return tz.local(parsed.year, parsed.month, parsed.day, parsed.hour, parsed.min, parsed.sec)
      end
      nil
    end

    def parse_datetime(str)
      try_parse(str) || raise("Cannot parse datetime: #{str}")
    end
  end
end
