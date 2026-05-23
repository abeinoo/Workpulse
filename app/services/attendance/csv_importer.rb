require "csv"

module Attendance
  # Parses and imports attendance records from a CSV file.
  #
  # Two-phase operation:
  #   1. parse(csv_data, business:)  — validates rows, returns ParseResult for preview
  #   2. execute(import_log)         — commits valid rows from a pending import log
  #
  # CSV columns: employee_code (required), check_in_at (required), check_out_at (optional)
  # Datetime formats accepted: "YYYY-MM-DD HH:MM", "YYYY-MM-DD HH:MM:SS",
  #                            "DD/MM/YYYY HH:MM", "DD/MM/YYYY HH:MM:SS"
  class CsvImporter
    REQUIRED_COLUMNS = %w[employee_code check_in_at].freeze
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
        headers:           true,
        skip_blanks:       true,
        strip:             true
      )

      # Normalise headers to lowercase, stripped
      headers = table.headers.map { |h| h.to_s.strip.downcase }
      missing = REQUIRED_COLUMNS - headers
      if missing.any?
        return ParseResult.new(
          rows:          [],
          total_rows:    0,
          headers_valid: false,
          header_error:  "Missing required columns: #{missing.join(', ')}"
        )
      end

      rows = table.each_with_index.map { |row, i| validate_row(row, i + 2) }

      ParseResult.new(
        rows:          rows,
        total_rows:    rows.size,
        headers_valid: true,
        header_error:  nil
      )
    end

    # ── Phase 2: commit ───────────────────────────────────────────────────────

    def execute(import_log)
      valid_rows    = import_log.valid_preview_rows
      imported      = 0
      runtime_fails = []

      valid_rows.each do |row|
        begin
          user       = @business.users.find_by!(employee_code: row["employee_code"])
          check_in   = parse_datetime(row["check_in_at"])
          check_out  = row["check_out_at"].present? ? parse_datetime(row["check_out_at"]) : nil
          work_date  = check_in.to_date

          shift_assignment = ShiftAssignment
                               .where(user_id: user.id)
                               .active_on(work_date)
                               .first

          record    = AttendanceRecord.find_or_initialize_by(user_id: user.id, work_date: work_date)
          is_new    = record.new_record?

          if is_new
            record.date                = work_date
            record.branch_id           = shift_assignment&.branch_id
            record.shift_assignment    = shift_assignment
            record.late_minutes        = 0
            record.early_leave_minutes = 0
          end

          # Merge: take earliest check_in
          record.check_in_at = check_in if is_new || check_in < record.check_in_at

          # Merge: take latest check_out
          if check_out.present? && (record.check_out_at.nil? || check_out > record.check_out_at)
            record.check_out_at = check_out
          end

          # Recalculate derived fields from merged timestamps
          record.status         = derive_status(record.check_out_at)
          record.worked_minutes = worked_minutes(record.check_in_at, record.check_out_at)
          record.save!

          imported += 1
        rescue => e
          runtime_fails << row.merge("error" => e.message)
        end
      end

      total_failed = import_log.failed_rows_count + runtime_fails.size
      import_log.update!(
        status:           "completed",
        imported_rows:    imported,
        failed_rows_count: total_failed,
        metadata:         import_log.metadata.merge("failed" => runtime_fails)
      )
    end

    private

    def validate_row(row, row_number)
      employee_code = row["employee_code"]&.strip
      check_in_str  = row["check_in_at"]&.strip
      check_out_str = row["check_out_at"]&.strip

      errs         = []
      user         = nil
      check_in_at  = nil
      check_out_at = nil

      if employee_code.blank?
        errs << "employee_code is required"
      else
        user = @business.users.find_by(employee_code: employee_code)
        errs << "Employee '#{employee_code}' not found" unless user
      end

      if check_in_str.blank?
        errs << "check_in_at is required"
      else
        check_in_at = try_parse(check_in_str)
        errs << "check_in_at '#{check_in_str}' is not a valid datetime" unless check_in_at
      end

      if check_out_str.present?
        check_out_at = try_parse(check_out_str)
        if check_out_at.nil?
          errs << "check_out_at '#{check_out_str}' is not a valid datetime"
        elsif check_in_at && check_out_at <= check_in_at
          errs << "check_out_at must be after check_in_at"
        end
      end

      {
        "row"           => row_number,
        "employee_code" => employee_code,
        "employee_name" => user&.full_name,
        "check_in_at"   => check_in_str,
        "check_out_at"  => check_out_str.presence,
        "work_date"     => check_in_at&.to_date&.to_s,
        "valid"         => errs.empty?,
        "errors"        => errs
      }
    end

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

    def derive_status(check_out_at)
      check_out_at.present? ? "present" : "incomplete"
    end

    def worked_minutes(check_in_at, check_out_at)
      return nil unless check_out_at
      ((check_out_at - check_in_at) / 60).round
    end
  end
end
